#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"

require "async/matrix/bridge"
require "ratalada/async"

Bridge = Async::Matrix::Bridge

# The registration file is the one the homeserver already reads, validated
# against the Matrix spec's own schema. Nothing is restated here -- only the
# homeserver address and server_name, which a registration cannot carry.
config = Bridge::Registration.load(
  ENV.fetch("REGISTRATION", "/config/appservice-agent.yaml"),
  homeserver: ENV.fetch("HOMESERVER", "http://synapse:8008"),
  domain: ENV.fetch("DOMAIN", "localhost")
)

client = Async::Matrix::Client.new(config)
store = Bridge::TransactionStore.new
bot = config.bot_mxid

Server.run(host: "0.0.0.0", port: Integer(ENV.fetch("PORT", "9000"))) do |request|
  Bridge::Endpoint.new(request.env, config: config, store: store) do |message|
    case message
    in {type: "m.room.member", content: {membership: "invite"}, room_id:, state_key: ^bot}
      client.join_room(room_id)
    in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:, sender:} if sender != bot
      client.send_notice(room_id, "Echo: #{body}")
    else
      nil
    end
  end
end
