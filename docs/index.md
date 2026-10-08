---
layout: default
title: async-matrix-bridge
nav_order: 1
description: 'An async-native Matrix Application Service SDK for Ruby. Fibers, not threads — built on async-matrix and the Socketry ecosystem (async, async-http, Falcon).'
permalink: /
---

# async-matrix-bridge

An async-native [Matrix](https://matrix.org) Application Service SDK for Ruby. Built on [async-matrix](https://general-intelligence-systems.github.io/async-matrix/) and the [Socketry](https://github.com/socketry) ecosystem (`async`, `async-http`) — no threads, no callbacks, just fibers.
{: .fs-6 .fw-300 }

<div class="hero-actions">
  <a href="{% link _getting_started/getting-started.md %}" class="btn btn-primary fs-5 mb-4 mb-md-0 mr-2">Get started</a>
  <a href="https://github.com/general-intelligence-systems/async-matrix-bridge" class="btn fs-5 mb-4 mb-md-0 mr-2">GitHub</a>
</div>

async-matrix-bridge implements the [Matrix Application Service API](https://spec.matrix.org/latest/application-service-api/): the server side of a bridge or bot. Your homeserver `PUT`s transactions of events at your service; async-matrix-bridge authenticates them, deduplicates them, and hands each event to a block you pattern match on — concurrently, each in its own fiber. Calls back to the homeserver go through async-matrix's `Client`. The whole stack runs on fibers, so thousands of concurrent HTTP calls cost you connection-pool slots, not threads.

## Quick start

```ruby
require "async/matrix/bridge"
require "ratalada/async"

Bridge = Async::Matrix::Bridge

config = Bridge::Registration.load("/config/registration.yaml",
  homeserver: "http://synapse:8008", domain: "localhost")

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

That is a complete echo bot. The whole protocol is `Endpoint`: it authenticates the homeserver, deduplicates the transaction, and hands you each event to match on. There is no handler object to register and no base class to inherit. Head to [Getting Started]({% link _getting_started/getting-started.md %}) for a walkthrough with a real homeserver.

`Endpoint` also takes a `Protocol::HTTP::Request` instead of a Rack env, so the same class serves a bare `Async::HTTP::Server` with no Rack in the stack at all.

## What's here

- **Core Features** — the [Application Service endpoint]({% link _core_features/application-service.md %}), its routes, idempotency and concurrency, and [pattern matching]({% link _core_features/pattern-matching.md %}) the events it hands you.
- **Advanced** — [configuration]({% link _advanced/configuration.md %}) from the registration file, validated against the Matrix spec's own schema.
- **Examples** — [two runnable services]({% link _examples/examples.md %}), one on Rack and one without, sharing a Docker Compose + Synapse stack.

The Matrix protocol layer this gem builds on is documented separately: the [Client](https://general-intelligence-systems.github.io/async-matrix/client/) and its schema-validated API chain, [events and schema validation](https://general-intelligence-systems.github.io/async-matrix/events-and-schemas/), [end-to-end encryption](https://general-intelligence-systems.github.io/async-matrix/encryption/) and [media](https://general-intelligence-systems.github.io/async-matrix/media/).

## Design principles

1. **Async all the way down.** Every HTTP call is a fiber operation on `Async::HTTP::Internet` with fiber-safe connection pooling, and the events of a transaction dispatch concurrently under a bounded semaphore. No thread pools, no callback soup.
2. **The homeserver is untrusted input.** Transactions are authenticated with a constant-time token compare and deduplicated by transaction ID before anything runs.
3. **Losing an event is worse than being slow.** A transaction is recorded as seen only after it has been handled without raising; otherwise it answers `500` and the homeserver retries, rather than being silently dropped.
4. **Specs are the source of truth.** The registration file validates against the Matrix spec's own JSON Schema, vendored verbatim rather than transcribed.
5. **Ruby, not a framework.** Dispatch is `case/in`, filters are pins and guards, and configuration is the registration file the homeserver already reads.
