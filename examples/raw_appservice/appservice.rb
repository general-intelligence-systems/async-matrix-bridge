#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"

require "async"
require "async/http/server"
require "async/http/endpoint"
require "async/matrix/bridge"

Bridge = Async::Matrix::Bridge

config = Bridge::Registration.load(
  ENV.fetch("REGISTRATION", "/config/appservice-raw.yaml"),
  homeserver: ENV.fetch("HOMESERVER", "http://synapse:8008"),
  domain: ENV.fetch("DOMAIN", "localhost")
)

# The protocol is left to the endpoint rather than pinned to HTTP2: a
# homeserver pushes transactions over HTTP/1.1 and will not do h2c with prior
# knowledge, so a listener forced to HTTP2 never receives an event.
endpoint = Async::HTTP::Endpoint.parse(
  "http://#{ENV.fetch("BIND", "0.0.0.0")}:#{ENV.fetch("PORT", "9001")}",
  reuse_port: true
)

Async do
  client = Async::Matrix::Client.new(config)
  store = Bridge::TransactionStore.new
  bot = config.bot_mxid

  Console.info(self) { "Raw appservice #{config.id} listening as #{bot}" }

  server = Async::HTTP::Server.for(endpoint) do |request|
    Bridge::Endpoint.new(request, config: config, store: store) do |message|
      case message
      in {type: "m.room.member", content: {membership: "invite"}, room_id:, state_key: ^bot}
        client.join_room(room_id)
      in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:, sender:} if sender != bot
        client.send_notice(room_id, "Raw echo: #{body}")
      else
        nil
      end
    end.response
  end

  server.run
end
