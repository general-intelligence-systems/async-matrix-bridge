# frozen_string_literal: true

require "bundler/setup"

require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/rack/adapter"
require "async/matrix/bridge"

Bridge = Async::Matrix::Bridge

config = Bridge::Registration.load(
  ENV.fetch("REGISTRATION", "/config/appservice-raw.yaml"),
  homeserver: ENV.fetch("HOMESERVER", "http://synapse:8008"),
  domain: ENV.fetch("DOMAIN", "localhost")
)

endpoint = Async::HTTP::Endpoint.parse(
  "http://#{ENV.fetch("BIND", "0.0.0.0")}:#{ENV.fetch("PORT", "9001")}",
  reuse_port: true
)

Async do
  client = Async::Matrix::Client.new(config)
  bot = config.bot_mxid

  Console.info(self) { "Raw appservice #{config.id} listening as #{bot}" }

  appservice = Bridge::Endpoint.new(config: config, store: Bridge::TransactionStore.new) do |message|
    case message
    in {type: "m.room.member", content: {membership: "invite"}, room_id:, state_key: ^bot}
      client.join_room(room_id)
    in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:, sender:} if sender != bot
      client.send_notice(room_id, "Raw echo: #{body}")
    else
      nil
    end
  end

  server = Async::HTTP::Server.new(Protocol::Rack::Adapter.new(appservice), endpoint)

  server.run
end
