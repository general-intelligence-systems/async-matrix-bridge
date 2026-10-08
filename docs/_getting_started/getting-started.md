---
layout: default
title: Getting Started
nav_order: 1
description: Install async-matrix-bridge, register an application service with your homeserver, and run your first bot.
---

# Getting Started

This guide registers an application service with a homeserver and runs an echo bot against it.

## Requirements

- Ruby >= 3.3
- A Matrix homeserver you can add a registration file to ([Synapse](https://github.com/element-hq/synapse), for example)

## Install

```ruby
gem "async-matrix-bridge"
```

An `Endpoint` is not a Rack app, so no Rack server is required. Add one only if you want to run inside a Rack stack:

```ruby
gem "ratalada"        # the DSL used below
gem "protocol-rack"   # its Rack adapter
```

## Register with the homeserver

Write a registration file. The tokens are secrets you invent; generate them with `SecureRandom.urlsafe_base64(32)`.

```yaml
# registration.yaml
id: agent
url: "http://appservice:9000"
as_token: "..."
hs_token: "..."
sender_localpart: agent
namespaces:
  users:
    - exclusive: false
      regex: "@.*:localhost"
  aliases: []
  rooms: []
```

Point the homeserver at it. In Synapse's `homeserver.yaml`:

```yaml
app_service_config_files:
  - /config/registration.yaml
```

Synapse reads registrations at startup only, so restart it. Note also that `url` must not contain an underscore — Synapse's IDNA handling rejects underscores in hostnames.

## The service

```ruby
#!/usr/bin/env ruby
require "async/matrix/bridge"
require "ratalada/async"

Bridge = Async::Matrix::Bridge

config = Bridge::Registration.load("/config/registration.yaml",
  homeserver: "http://synapse:8008",
  domain: "localhost")

client = Async::Matrix::Client.new(config)
store = Bridge::TransactionStore.new
bot = config.bot_mxid

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

Run it with `ruby appservice.rb`.

## Check it

The healthcheck needs no authentication:

```bash
curl -i -X POST http://localhost:9000/_matrix/app/v1/ping        # 200 {}
```

An unauthenticated transaction must be refused:

```bash
curl -i -X PUT -d '{}' -H 'content-type: application/json' \
  http://localhost:9000/_matrix/app/v1/transactions/1           # 403 M_FORBIDDEN
```

Then invite `@agent:localhost` to a room and say something. The bot joins on the invite and echoes the message.

## Encryption

The bot has no crypto, so an encrypted room delivers undecryptable `m.room.encrypted` events and nothing will echo. Create an unencrypted room for testing — note that some clients enable encryption on room creation regardless of the server's default.

## Next

- [Application Service]({% link _core_features/application-service.md %}) — routes, idempotency, concurrency, retries
- [Pattern Matching]({% link _core_features/pattern-matching.md %}) — the matcher block in depth
- [Configuration]({% link _advanced/configuration.md %}) — `Registration` and its schema
- [Examples]({% link _examples/examples.md %}) — runnable Docker Compose stacks
