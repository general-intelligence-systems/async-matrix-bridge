---
layout: default
title: Examples
nav_order: 1
description: Two runnable application services — one on a Rack stack, one on a bare Async::HTTP server — sharing a Synapse Docker Compose stack.
---

# Examples

The [`examples/`](https://github.com/general-intelligence-systems/async-matrix-bridge/tree/main/examples) directory holds two complete services and the Synapse stack they run against. Both are the same echo bot, differing only in the server they are mounted on.

```bash
cd examples
docker compose up --build
```

Synapse comes up on `:8008`, with both services registered against it.

## The shared Synapse stack

`examples/synapse/` is a throwaway rig: SQLite in `/tmp`, a `modules/any_password.py` auth provider that accepts any password and registers the user on first login, and encryption off by default for locally-created rooms. Nothing in it is worth protecting — never expose it.

Two registration files are mounted, one per service, each with its own id, tokens and `sender_localpart`.

## `appservice/` — on a Rack stack

Runs on [ratalada](https://github.com/n-at-han-k/ratalada)'s `async` backend. `Endpoint` returns a Rack triplet, so it goes straight into the router block.

```ruby
Server.run(host: "0.0.0.0", port: 9000) do |request|
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
```

Joins as `@agent:localhost` and answers `Echo: ...`.

## `raw_appservice/` — no Rack at all

A bare `Async::HTTP::Server`. Its Gemfile is a single gem: no ratalada, no protocol-rack, no falcon. The same `Endpoint` takes the `Protocol::HTTP::Request` and `#response` hands back a `Protocol::HTTP::Response`.

```ruby
server = Async::HTTP::Server.for(endpoint) do |request|
  Bridge::Endpoint.new(request, config: config, store: store) do |message|
    case message
    in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:, sender:} if sender != bot
      client.send_notice(room_id, "Raw echo: #{body}")
    else
      nil
    end
  end.response
end

server.run
```

Joins as `@raw:localhost` and answers `Raw echo: ...`.

The protocol is deliberately left to the endpoint rather than pinned to HTTP/2: a homeserver pushes transactions over HTTP/1.1 and will not do h2c with prior knowledge, so a forced-HTTP2 listener never receives an event.

## Trying it

Log in as any user with any password, invite both bots to an **unencrypted** room, and send a message — you get two replies, from two different server stacks.

```bash
matrix-commander --login password --homeserver http://localhost:8008 \
  --user-login alice --password secret --device mc \
  --credentials ./credentials.json --store ./store

matrix-commander -c ./credentials.json -s ./store --room '!your:room' -m "hello"
```

Create the room through the Client-Server API rather than `matrix-commander --room-create`, which turns encryption on regardless of the server default.
