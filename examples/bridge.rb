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

Async do |task|
  Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].open(HOMESERVER) do |client|
    registration = Bridge::Registration.load(REGISTRATION, homeserver: HOMESERVER)
    room_alias = "#_bridge_#{CHANNEL}:#{registration.domain}"

    connections = []

    machines = {}

    relay = registration.puppet(client, "_bridge_relay")

    relay.register!

    relay_device = "RELAY-#{SecureRandom.hex(3).upcase}"

    relay.device!(relay_device, display_name: "Bridge")

    reader = relay.on(relay_device)

    machines[relay.user_id] = Async::Matrix::E2EE::Machine.new(
      user_id: relay.user_id,
      device_id: relay_device,
      crypto: Async::Matrix::E2EE::Olm.new,
    )

    machine = machines[relay.user_id]

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
      created = reader.create_room(
        name: "##{CHANNEL}",
        room_alias_name: "_bridge_#{CHANNEL}",
        preset: "public_chat",
        initial_state: initial_state,
      )

      created.id
    end

    Console.info(self, "Bridging.", channel: CHANNEL, room_id: room_id, as: relay.user_id)

    puppet_for = lambda do |nick|
      user = registration.puppet(client, "_bridge_#{nick}")

      unless machines.key?(user.user_id)
        device_id = "REMOTE-#{SecureRandom.hex(3).upcase}"

        user.register!
        user.device!(device_id, display_name: nick)

        crypto = Async::Matrix::E2EE::Machine.new(
          user_id: user.user_id,
          device_id: device_id,
          crypto: Async::Matrix::E2EE::Olm.new,
        )

        crypto.crypto.generate_one_time_keys(crypto.crypto.one_time_key_target)
        user.on(device_id).keys.upload_keys(
          device_keys: crypto.device_keys,
          one_time_keys: crypto.signed_one_time_keys,
        )
        crypto.crypto.published_one_time_keys!

        user.client.join_room(room_id)

        machines[user.user_id] = {puppet: user, device_id: device_id, crypto: crypto}

        Console.info(self, "A nick arrived.", nick: nick, user_id: user.user_id)
      end

      machines[user.user_id]
    end

    encrypted = lambda do
      reader.room(room_id).get_room_state_with_key("m.room.encryption")

      true
    rescue Async::Matrix::RequestError
      false
    end

    say = lambda do |nick, body, at|
      known = puppet_for.call(nick)
      content = Async::Matrix::Events::TextMessage.build(body: body)
      sending = known[:puppet].on(known[:device_id], ts: at)

      case encrypted.call
      in false
        sending.room(room_id).send_message(content.type, content.to_h)
      in true
        crypto = known[:crypto]

        members = reader.room(room_id).get_joined_members_by_room.user_ids
        queried = sending.keys.query_keys(members.to_h{|id| [id, []]})
        recipients = crypto.recipients(queried)
        wanted = crypto.without_sessions(recipients)

        unless wanted.empty?
          crypto.accept_claimed_keys(sending.keys.claim_keys(wanted))
        end

        session = crypto.session_for(room_id)

        messages = recipients.group_by(&:user_id).transform_values do |devices|
          devices.to_h do |device|
            [device.device_id, crypto.encrypt_to_device(device, "m.room_key", {
              algorithm: MEGOLM,
              room_id: room_id,
              session_id: session[:session_id],
              session_key: session[:session_key],
            })]
          end
        end

        sending.to_device.send_to_device("m.room.encrypted", messages)

        encrypted_content = crypto.encrypt(room_id, content)
        sending.room(room_id).send_message(encrypted_content.type, encrypted_content.to_h)
      end

      Console.info(self, "Said it on Matrix.", nick: nick, body: body, encrypted: encrypted.call)
    end

    handler = lambda do |event, source|
      case event
      in {sender: String => sender} if registration.covers?("users", sender)
        nil

      in {room_id: ^room_id, sender:, content: Async::Matrix::Events::TextMessage(body:)}
        line = "<#{sender}> #{body}\n"

        connections.each{|stream| stream.write(line)}
        connections.each(&:flush)

        Console.info(self, "Carried it to the network.", via: source, sender: sender, body: body, to: connections.size)

      in {room_id: waiting_room, session_id:, content: Async::Matrix::Events::Deferred}
        Console.info(self, "Waiting for a session.", room_id: waiting_room, session_id: session_id)

      in {sender:, content: Async::Matrix::Events::Withheld(code:)}
        connections.each{|stream| stream.write("* a message from #{sender} could not be read (#{code})\n")}
        connections.each(&:flush)

      in {room_id: invited_to, state_key:, content: Async::Matrix::Events::RoomMember(membership: "invite")} if state_key == relay.user_id
        relay.client.join_room(invited_to)
      else
        nil
      end
    end

    task.async do
      reader.sync(timeout: 0, filter: KEYS_ONLY).each(retries: 3) do |batch|
        machine.each_event(batch){|event| handler.call(event, :sync)}
      end
    end

    task.async do
      IO::Endpoint.tcp("0.0.0.0", REMOTE_PORT).accept do |stream|
        nick = stream.gets&.chomp

        case nick
        in nil | ""
          stream.close
        in String
          connections << stream

          Console.info(self, "Somebody joined the network.", nick: nick)

          while line = stream.gets
            body = line.chomp

            unless body.empty?
              say.call(nick, body, (Time.now.to_f * 1000).to_i)
            end
          end

          connections.delete(stream)
        end
      end
    end

    service = Bridge::Service.new(registration) do |transaction|
      transaction.each_room do |pushed_room, events|
        events.each do |event|
          case event
          in {content: Async::Matrix::Events::RoomEncrypted}
            case machine.decrypt(event, room_id: pushed_room)
            in nil
              Console.debug(self, "Deferred.", room_id: pushed_room)
            in Async::Matrix::Events::Envelope => decrypted
              handler.call(decrypted, :transaction)
            end
          else
            handler.call(event, :transaction)
          end
        end
      end
    end

    service.query_user{|user_id| registration.covers?("users", user_id)}
    service.query_room{|asked| asked == room_alias}

    Console.info(self, "Listening.", matrix: PORT, network: REMOTE_PORT)

    Async::HTTP::Server.new(service, Async::HTTP::Endpoint.parse("http://0.0.0.0:#{PORT}")).run
  end
end
