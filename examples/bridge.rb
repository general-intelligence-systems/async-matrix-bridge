#!/usr/bin/env ruby
# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require_relative "../lib/async/matrix/bridge"

require "async/matrix/e2ee"

require "async"
require "async/http/endpoint"
require "async/http/server"
require "io/endpoint/host_endpoint"
require "console"
require "securerandom"

HOMESERVER = ENV.fetch("HOMESERVER", "http://localhost:7400")
REGISTRATION = ENV.fetch("REGISTRATION", "./synapse/appservice.yaml")
PORT = Integer(ENV.fetch("PORT", "9000"))
REMOTE_PORT = Integer(ENV.fetch("REMOTE_PORT", "9100"))

CHANNEL = ENV.fetch("CHANNEL", "lobby")

MEGOLM = "m.megolm.v1.aes-sha2"

KEYS_ONLY = ::JSON.generate({room: {rooms: []}, presence: {types: []}})

Bridge = Async::Matrix::Bridge

Nick = Data.define(:puppet, :device_id, :machine)

Bridging = Data.define(:registration, :client, :relay, :reader, :machine, :room_id, :encrypted, :connections, :nicks)

def carry(event, bridging)
  case event
  in {sender: String => sender} if bridging.registration.covers?("users", sender)
    nil

  in {content: Async::Matrix::Events::RoomEncrypted} if (plain = bridging.machine.decrypt(event, room_id: event.room_id))
    carry(plain, bridging)

  in {content: Async::Matrix::Events::RoomEncrypted}
    Console.info(self, "Deferred an event.", room_id: event.room_id)

  in {room_id: String => said_in, sender: String => sender, content: Async::Matrix::Events::TextMessage(body:)} if said_in == bridging.room_id
    bridging.connections.each{|stream| stream.write("<#{sender}> #{body}\n")}
    bridging.connections.each(&:flush)

    Console.info(self, "Carried it to the network.", sender: sender, body: body, to: bridging.connections.size)

  in {sender: String => sender, content: Async::Matrix::Events::Withheld(code:)}
    bridging.connections.each{|stream| stream.write("* a message from #{sender} could not be read (#{code})\n")}
    bridging.connections.each(&:flush)

  in {room_id: String => invited_to, state_key: String => invited, content: Async::Matrix::Events::RoomMember(membership: "invite")} if invited == bridging.relay.user_id
    bridging.relay.client.join_room(invited_to)

  else
    nil
  end
end

def say(nick, body, bridging)
  unless bridging.nicks.key?(nick)
    puppet = bridging.registration.puppet(bridging.client, "_bridge_#{nick}")
    device_id = "REMOTE-#{SecureRandom.hex(3).upcase}"

    puppet.register!
    puppet.device!(device_id, display_name: nick)

    speaking = Async::Matrix::E2EE::Machine.new(
      user_id: puppet.user_id,
      device_id: device_id,
      crypto: Async::Matrix::E2EE::Olm.new,
    )

    speaking.crypto.generate_one_time_keys(speaking.crypto.one_time_key_target)
    puppet.on(device_id).keys.upload_keys(
      device_keys: speaking.device_keys,
      one_time_keys: speaking.signed_one_time_keys,
    )
    speaking.crypto.published_one_time_keys!

    puppet.client.join_room(bridging.room_id)

    bridging.nicks[nick] = Nick.new(puppet: puppet, device_id: device_id, machine: speaking)

    Console.info(self, "A nick arrived.", nick: nick, user_id: puppet.user_id)
  end

  speaker = bridging.nicks[nick]
  content = Async::Matrix::Events::TextMessage.build(body: body)
  sending = speaker.puppet.on(speaker.device_id, ts: (Time.now.to_f * 1000).to_i)

  case bridging.encrypted
  in false
    sending.room(bridging.room_id).send_message(content.type, content.to_h)

  in true
    members = bridging.reader.room(bridging.room_id).get_joined_members_by_room.user_ids
    recipients = speaker.machine.recipients(sending.keys.query_keys(members.to_h{|id| [id, []]}))
    wanted = speaker.machine.without_sessions(recipients)

    unless wanted.empty?
      speaker.machine.accept_claimed_keys(sending.keys.claim_keys(wanted))
    end

    session = speaker.machine.session_for(bridging.room_id)

    messages = recipients.group_by(&:user_id).transform_values do |devices|
      devices.to_h do |device|
        [device.device_id, speaker.machine.encrypt_to_device(device, "m.room_key", {
          algorithm: MEGOLM,
          room_id: bridging.room_id,
          session_id: session[:session_id],
          session_key: session[:session_key],
        })]
      end
    end

    sending.to_device.send_to_device("m.room.encrypted", messages)

    ciphertext = speaker.machine.encrypt(bridging.room_id, content)

    sending.room(bridging.room_id).send_message(ciphertext.type, ciphertext.to_h)
  end

  Console.info(self, "Said it on Matrix.", nick: nick, body: body, encrypted: bridging.encrypted)
end

Async do |task|
  Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].open(HOMESERVER) do |client|
    registration = Bridge::Registration.load(REGISTRATION, homeserver: HOMESERVER)
    room_alias = "#_bridge_#{CHANNEL}:#{registration.domain}"

    connections = []

    nicks = {}

    relay = registration.puppet(client, "_bridge_relay")

    relay.register!

    relay_device = "RELAY-#{SecureRandom.hex(3).upcase}"

    relay.device!(relay_device, display_name: "Bridge")

    reader = relay.on(relay_device)

    machine = Async::Matrix::E2EE::Machine.new(
      user_id: relay.user_id,
      device_id: relay_device,
      crypto: Async::Matrix::E2EE::Olm.new,
    )

    machine.crypto.generate_one_time_keys(machine.crypto.one_time_key_target)
    reader.keys.upload_keys(device_keys: machine.device_keys, one_time_keys: machine.signed_one_time_keys)
    machine.crypto.published_one_time_keys!

    initial_state = case ENV.fetch("ENCRYPTED", "false")
    in "true"
      [{type: "m.room.encryption", state_key: "", content: {algorithm: MEGOLM}}]
    else
      []
    end

    room_id = begin
      client.directory.get_room_id_by_alias(room_alias).room_id
    rescue Async::Matrix::RequestError
      reader.create_room(
        name: "##{CHANNEL}",
        room_alias_name: "_bridge_#{CHANNEL}",
        preset: "public_chat",
        initial_state: initial_state,
      ).id
    end

    encrypted = begin
      reader.room(room_id).get_room_state_with_key("m.room.encryption")

      true
    rescue Async::Matrix::RequestError
      false
    end

    bridging = Bridging.new(
      registration: registration,
      client: client,
      relay: relay,
      reader: reader,
      machine: machine,
      room_id: room_id,
      encrypted: encrypted,
      connections: connections,
      nicks: nicks,
    )

    Console.info(self, "Bridging.", channel: CHANNEL, room_id: room_id, as: relay.user_id, encrypted: encrypted)

    task.async do
      reader.sync(timeout: 0, filter: KEYS_ONLY).each(retries: 3) do |batch|
        machine.each_event(batch){|event| carry(event, bridging)}
      end
    end

    task.async do
      IO::Endpoint.tcp("0.0.0.0", REMOTE_PORT).accept do |stream|
        case stream.gets&.chomp
        in nil | ""
          stream.close

        in String => nick
          connections << stream

          Console.info(self, "Somebody joined the network.", nick: nick)

          while line = stream.gets
            body = line.chomp

            unless body.empty?
              say(nick, body, bridging)
            end
          end

          connections.delete(stream)
        end
      end
    end

    service = Bridge::Service.new(registration) do |transaction|
      transaction.each_room do |_room_id, pushed|
        pushed.each{|event| carry(event, bridging)}
      end
    end

    service.query_user{|user_id| registration.covers?("users", user_id)}
    service.query_room{|asked| asked == room_alias}

    Console.info(self, "Listening.", matrix: PORT, network: REMOTE_PORT)

    Async::HTTP::Server.new(service, Async::HTTP::Endpoint.parse("http://0.0.0.0:#{PORT}")).run
  end
end
