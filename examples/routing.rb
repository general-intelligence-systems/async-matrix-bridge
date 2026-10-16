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

Routing = Data.define(:registration, :bridge, :reader, :machine, :connections)

def route(event, routing)
  case event
  in {sender: String => sender} if routing.registration.covers?("users", sender)
    nil

  in {content: Async::Matrix::Events::RoomEncrypted} if (plain = routing.machine.decrypt(event, room_id: event.room_id))
    route(plain, routing)

  in {content: Async::Matrix::Events::RoomEncrypted}
    Console.info(self, "Deferred an event.", room_id: event.room_id, session_id: event.content[:session_id])

  in {room_id: String => invited_to, state_key: String => invited, content: Async::Matrix::Events::RoomMember(membership: "invite")} if routing.registration.covers?("users", invited)
    routing.bridge.client.join_room(invited_to)

  in {room_id: String => said_in, sender: String => sender, content: Async::Matrix::Events::TextMessage(body:)}
    owners = begin
      routing.reader.room(said_in).get_joined_members_by_room.user_ids.filter_map do |member|
        localpart = member.to_s.delete_prefix("@").split(":", 2).first.to_s

        localpart.delete_prefix(PREFIX).split("_").first if localpart.start_with?(PREFIX)
      end
    rescue Async::Matrix::RequestError
      []
    end

    case owners.first
    in nil
      Console.warn(self, "No bridge owns that room.", room_id: said_in)

    in String => stream
      routing.connections.each{|connection| connection.write("#{stream} #{sender} #{body}\n")}
      routing.connections.each(&:flush)

      Console.info(self, "Routed it.", stream: stream, event_id: event[:event_id], sender: sender)
    end

  in {session_id: String => refused, content: Async::Matrix::Events::Withheld(code:)}
    Console.warn(self, "A session was withheld.", session_id: refused, code: code)

  in {session_id: String => broken, content: Async::Matrix::Events::Undecryptable}
    Console.error(self, "Could not read an event.", session_id: broken)

  else
    nil
  end
end

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

    routing = Routing.new(
      registration: registration,
      bridge: bridge,
      reader: reader,
      machine: machine,
      connections: connections,
    )

    Console.info(self, "Routing.", channel: CHANNEL, room_id: room_id, as: bridge.user_id)

    task.async do
      reader.sync(timeout: 0, filter: KEYS_ONLY).each(retries: 3) do |batch|
        machine.each_event(batch){|event| route(event, routing)}
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
      transaction.each_room do |_room_id, pushed|
        pushed.each{|event| route(event, routing)}
      end
    end

    service.query_user{|user_id| registration.covers?("users", user_id)}
    service.query_room{|asked| asked == room_alias}

    Console.info(self, "Listening.", matrix: PORT, streams: REMOTE_PORT)

    Async::HTTP::Server.new(service, Async::HTTP::Endpoint.parse("http://0.0.0.0:#{PORT}")).run
  end
end
