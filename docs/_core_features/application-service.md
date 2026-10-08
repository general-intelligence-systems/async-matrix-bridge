---
layout: default
title: Application Service
nav_order: 1
description: The Endpoint class — the Matrix wire-protocol routes, authentication, idempotency, concurrent dispatch, and the Rack and Protocol::HTTP sources it serves.
---

# Application Service

`Bridge::Endpoint` is the server side of the [Matrix Application Service API](https://spec.matrix.org/latest/application-service-api/), in one class. It is built per request, holds no state of its own, and returns a response — so it drops into any server without being a framework.

## Constructing an endpoint

```ruby
Bridge = Async::Matrix::Bridge

config = Bridge::Registration.load("/config/registration.yaml",
  homeserver: "http://synapse:8008", domain: "localhost")

store = Bridge::TransactionStore.new

endpoint = Bridge::Endpoint.new(source, config: config, store: store) do |message|
  # one case/in over the whole protocol
end
```

| Argument | Meaning |
|---|---|
| `source` | A Rack env (`Hash`) or a `Protocol::HTTP::Request`. |
| `config:` | Anything answering `config.appservice.hs_token` — normally a {% raw %}`Registration`{% endraw %}. |
| `store:` | A `TransactionStore` for idempotency. Omitted, nothing is deduplicated. |
| `concurrency:` | Maximum events dispatched at once. Default 8. |

The endpoint is built per request *on purpose*: the two things that must outlive a request — the transaction store and your `Client` — are passed in or closed over, so nothing is hidden in global state.

## Routes

All under `/_matrix/app/v1`:

| Route | Behaviour |
|---|---|
| `PUT transactions/{txnId}` | Receives events. Authenticated, idempotent, dispatched concurrently. |
| `POST ping` | Healthcheck. **No** authentication, per spec. |
| `GET users/{userId}` | User existence query. `200`. |
| `GET rooms/{roomAlias}` | Room alias query. `404`. |
| `GET thirdparty/...` | Protocol, location and user lookups, routed to your block. |

Any other path answers `404` with `M_NOT_FOUND`, which makes an endpoint a natural fall-through for a router that matches its own routes first. Call `handled?` to ask instead of assume.

## Authentication

The `hs_token` is compared in constant time, and read from the `Authorization: Bearer` header or the legacy `access_token` query parameter. A mismatch is `403 M_FORBIDDEN`. `POST ping` is exempt.

## Idempotency

`TransactionStore` is an in-memory LRU of seen transaction IDs (capacity 1024, pruning the oldest half when full). It lives outside the endpoint because the endpoint is per request while the store must be long-lived.

A transaction id is recorded only *after* every handler has completed without raising. See [retries](#retries).

## Concurrent dispatch

The events of a transaction run in their own fibers under a bounded `Async::Semaphore`, and all of them are awaited before the response:

```ruby
Bridge::Endpoint.new(source, config: config, store: store, concurrency: 16) { ... }
```

Outside a reactor the same endpoint dispatches sequentially, so it still works under `Rack::MockRequest` in a test.

## Retries

If your block raises, the response is `500` and the transaction id is **not** recorded, so the homeserver retries the transaction. Recording it and answering `200` would make a failed handler drop its events permanently, because the retry would be deduplicated away.

A homeserver retries with exponential backoff and will not deliver newer transactions to that service until the failing one succeeds, so a permanently-failing handler stalls the service rather than silently losing events.

## Two sources, two response types

`Endpoint` accepts a Rack env or a `Protocol::HTTP::Request`, and answers with whichever type the source implies — a Rack triplet or a `Protocol::HTTP::Response`. An instance also defines `to_ary`, so it can be returned straight from a Rack router block.

```ruby
# Rack (ratalada, falcon, any Rack server)
Bridge::Endpoint.new(request.env, config: config, store: store) { ... }

# No Rack at all
Bridge::Endpoint.new(request, config: config, store: store) { ... }.response
```

Three differences between the sources are handled for you: a `Protocol::HTTP::Request`'s `path` carries the query string, its body reads chunk-wise rather than whole, and its `authorization` header is not a plain `String`.
