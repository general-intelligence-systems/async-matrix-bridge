#!/usr/bin/env ruby
# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

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

    bot = registration.as(client)

    Console.info(self, "The service itself.", user_id: bot.get_token_owner.user_id)

    alice = registration.puppet(client, "_bridge_alice")

    Console.info(self, "A puppet.", user_id: alice.user_id)

    alice.register!

    device_id = "IRC-#{SecureRandom.hex(4).upcase}"

    alice.device!(device_id, display_name: "Alice (IRC)")

    owner = alice.on(device_id).get_token_owner

    Console.info(self, "Acting as a device.", user_id: owner.user_id, device_id: owner.device_id)

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

    room = alice.on(device_id).create_room(name: "#channel", preset: "public_chat")
    content = Async::Matrix::Events::TextMessage.build(body: "Said on IRC.")

    said_at = (Time.now.to_f * 1000).to_i

    alice.on(device_id, ts: said_at).room(room.id).send_message(content.type, content.to_h)

    Console.info(self, "Said something as a puppet.", room_id: room.id)

    begin
      registration.as(client, "@someone-else:localhost")
    rescue ArgumentError => error
      Console.info(self, "Refused locally, as it should be.", error: error.message)
    end
  end
end
