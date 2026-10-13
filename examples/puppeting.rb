#!/usr/bin/env ruby
# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

# Acting as the users the registration lets us act as.
#
# A service holds one token and many identities. The token says which service, so the user is a parameter on every request: identity assertion rather than a login, which is why there is no password anywhere here.
#
# Each puppet is brought into existence twice over. Registering it makes the user, and the homeserver refuses to act as one it was never told about. Creating a device makes something to hold keys, and from v1.17 a service makes its own rather than logging in for one.
#
#   REGISTRATION=./registration.yaml HOMESERVER=http://localhost:8008 ruby examples/puppeting.rb

require_relative "../lib/async/matrix/bridge"

require "async/matrix/e2ee"

require "async"
require "console"
require "securerandom"

HOMESERVER = ENV.fetch("HOMESERVER", "http://localhost:8008")
REGISTRATION = ENV.fetch("REGISTRATION", "./registration.yaml")

Bridge = Async::Matrix::Bridge

Async do
  Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].open(HOMESERVER) do |client|
    registration = Bridge::Registration.load(REGISTRATION, homeserver: HOMESERVER)

    # No user named, so this acts as the `sender_localpart` the registration declares.
    bot = registration.as(client)

    Console.info(self, "The service itself.", user_id: bot.get_token_owner.user_id)

    # A puppet of our own, in the namespace the registration claims. Anything outside it is refused
    # here rather than by the homeserver, because the namespaces are the registration's own knowledge.
    alice = registration.puppet(client, "_bridge_alice")

    Console.info(self, "A puppet.", user_id: alice.user_id)

    # Registering is what makes the user. Doing it twice is not an error: a bridge does not remember
    # which of its puppets it has already made.
    alice.register!

    # A device is what holds keys. A service makes its own, which is what v1.17 added.
    #
    # Named per run, because the keys below belong to the Olm account which publishes them: a service
    # which did not keep that account cannot publish under the old device, and makes another instead.
    device_id = "IRC-#{SecureRandom.hex(4).upcase}"

    alice.device!(device_id, display_name: "Alice (IRC)")

    # And now it can be acted as, on that device, which is what encryption needs.
    owner = alice.on(device_id).get_token_owner

    Console.info(self, "Acting as a device.", user_id: owner.user_id, device_id: owner.device_id)

    # The keys that device publishes, which is what lets anybody encrypt to it.
    machine = Async::Matrix::E2EE::Machine.new(
      user_id: alice.user_id,
      device_id: device_id,
      crypto: Async::Matrix::E2EE::Olm.new,
    )

    machine.crypto.generate_one_time_keys(machine.crypto.one_time_key_target)

    uploaded = alice.on(device_id).keys.upload_keys(
      device_keys: machine.device_keys,
      one_time_keys: machine.signed_one_time_keys,
    )

    machine.crypto.published_one_time_keys!

    Console.info(self, "Published a puppet's keys.", counts: uploaded.one_time_key_counts)

    # Cross signing, without which nobody sends this device a room key: since MSC4153 a client
    # shares with cross signed devices and reports `m.unverified` to the rest.
    case machine.cross_signed?(alice.user_id, device_id)
    in true
      Console.info(self, "Already cross signed.")
    in false
      identity = machine.create_cross_signing_keys
      signing = alice.on(device_id).cross_signing

      signing.upload_cross_signing_keys(
        master_key: identity.master,
        self_signing_key: identity.self_signing,
        user_signing_key: identity.user_signing,
      )
      signing.upload_cross_signing_signatures(machine.sign_own_device)

      Console.info(self, "Cross signed a puppet.", master: identity.master_key)
    end

    # What the puppet is for: a room, and something in it which came from the other network.
    room = alice.on(device_id).create_room(name: "#channel", preset: "public_chat")
    content = Async::Matrix::Events::TextMessage.build(body: "Said on IRC.")

    # `ts` is timestamp massaging, which only a service may ask for: a bridge carrying a backlog says
    # when each message happened rather than stamping the lot as now.
    said_at = (Time.now.to_f * 1000).to_i

    alice.on(device_id, ts: said_at).room(room.id).send_message(content.type, content.to_h)

    Console.info(self, "Said something as a puppet.", room_id: room.id)

    # A user the registration does not cover, which never reaches the homeserver.
    begin
      registration.as(client, "@someone-else:localhost")
    rescue ArgumentError => error
      Console.info(self, "Refused locally, as it should be.", error: error.message)
    end
  end
end
