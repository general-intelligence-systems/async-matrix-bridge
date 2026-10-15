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

CHANNEL = ENV.fetch("CHANNEL", "echo")

MEGOLM = "m.megolm.v1.aes-sha2"

PREFIX = "_bridge_"

KEYS_ONLY = ::JSON.generate({room: {rooms: []}, presence: {types: []}})

Bridge = Async::Matrix::Bridge

Async do |task|
  Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].open(HOMESERVER) do |client|
    registration = Bridge::Registration.load(REGISTRATION, homeserver: HOMESERVER)
    room_alias = "##{PREFIX}#{CHANNEL}:#{registration.domain}"

    connections = []

    bridge = registration.puppet(client, "#{PREFIX}#{CHANNEL}")

    bridge.register!

    device_id = "ROUTER-#{SecureRandom.hex(3).upcase}"

    bridge.device!(device_id, display_name: CHANNEL)

    reader = bridge.on(device_id)

    machine = Async::Matrix::E2EE::Machine.new(
      user_id: bridge.user_id,
      device_id: device_id,
      crypto: Async::Matrix::E2EE::Olm.new,
    )

    machine.crypto.generate_one_time_keys(machine.crypto.one_time_key_target)
    reader.keys.upload_keys(device_keys: machine.device_keys, one_time_keys: machine.signed_one_time_keys)
    machine.crypto.published_one_time_keys!

    room_id = begin
      client.directory.get_room_id_by_alias(room_alias).room_id
    rescue Async::Matrix::RequestError
      reader.create_room(
        name: CHANNEL,
        room_alias_name: "#{PREFIX}#{CHANNEL}",
        preset: "public_chat",
        initial_state: [{type: "m.room.encryption", state_key: "", content: {algorithm: MEGOLM}}],
      ).id
    end

    Console.info(self, "Routing.", channel: CHANNEL, room_id: room_id, as: bridge.user_id)

    bridge_for = lambda do |named|
      localpart = named.to_s.delete_prefix("@").split(":", 2).first.to_s

      if localpart.start_with?(PREFIX)
        localpart.delete_prefix(PREFIX).split("_").first
      else
        nil
      end
    end

    stream_for = lambda do |asked|
      reader.room(asked).get_joined_members_by_room.user_ids.filter_map{|member| bridge_for.call(member)}.first
    rescue Async::Matrix::RequestError
      nil
    end

    route = lambda do |stream, event, sender, body|
      line = "#{stream} #{sender} #{body}\n"

      connections.each{|connection| connection.write(line)}
      connections.each(&:flush)

      Console.info(self, "Routed it.", stream: stream, event_id: event[:event_id], sender: sender)
    end

    handler = lambda do |event, source|
      case event
      in {sender: String => sender} if registration.covers?("users", sender)
        nil

      in {room_id: String => invited_to, state_key: String => invited, content: Async::Matrix::Events::RoomMember(membership: "invite")} if registration.covers?("users", invited)
        bridge.client.join_room(invited_to)

      in {room_id: String => said_in, sender: String => sender, content: Async::Matrix::Events::TextMessage(body:)}
        case stream_for.call(said_in)
        in nil
          Console.warn(self, "No bridge owns that room.", room_id: said_in, via: source)

        in String => stream
          route.call(stream, event, sender, body)
        end

      in {session_id: String => waiting_for, content: Async::Matrix::Events::Deferred}
        Console.info(self, "Waiting for a session.", session_id: waiting_for, via: source)

      in {sender: String => refused_by, content: Async::Matrix::Events::Withheld(code:)}
        Console.warn(self, "A session was withheld.", sender: refused_by, code: code, via: source)

      in {session_id: String => broken, content: Async::Matrix::Events::Undecryptable}
        Console.error(self, "Could not read an event.", session_id: broken, via: source)

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
      IO::Endpoint.tcp("0.0.0.0", REMOTE_PORT).accept do |connection|
        connections << connection

        while connection.gets
          nil
        end

        connections.delete(connection)
      end
    end

    service = Bridge::Service.new(registration) do |transaction|
      transaction.each_room do |pushed_room, events|
        events.each do |event|
          case event
          in {content: Async::Matrix::Events::RoomEncrypted}
            case machine.decrypt(event, room_id: pushed_room)
            in nil
              Console.info(self, "Deferred an event.", room_id: pushed_room, session_id: event.content[:session_id])

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

    Console.info(self, "Listening.", matrix: PORT, streams: REMOTE_PORT)

    Async::HTTP::Server.new(service, Async::HTTP::Endpoint.parse("http://0.0.0.0:#{PORT}")).run
  end
end
