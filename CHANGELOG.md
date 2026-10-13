# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

A second ground-up pass, this time with async-rest as the only reference. The
gem is five classes, the server side is middleware rather than a per-request
object, and the events are async-matrix's own event classes rather than Hashes.

### Added

- `Bridge::Service` — a `Protocol::HTTP::Middleware` answering the application
  service API, so it is served by an `Async::HTTP::Server` with no Rack
  anywhere. One `case` on method and path, authentication by constant-time
  compare of a Bearer token or the legacy `?access_token=`, and a `404` for
  anything outside `/_matrix/app/v1` decided before authentication, so a
  `/healthz` beside it is a `404` rather than a `403`. The user, room and
  third-party queries are three blocks rather than three routes.

- `Bridge::Transaction` — one pushed transaction as an
  `Async::Matrix::Representation`, parsed with async-rest's own JSON parser and
  typed through async-matrix's event registry. `each_room` groups a
  transaction's events by room, in the order they arrived.

- `Bridge::Puppet` — one user the service may act as, with `client`, `on` for
  a device and `register!` / `device!` for provisioning it. A localpart outside
  the registration's namespaces is refused locally.

- `Registration#as` — identity assertion, as a resource derived with `#with`:
  `user_id`, `device_id` (v1.17) and `ts` (v1.3) are parameters on the request
  rather than a login. `bot` and `puppet` name the two identities a service
  has.

- `examples/bridge.rb` — a working two-way bridge between Matrix and a line
  protocol, encrypted rooms included, and `examples/puppeting.rb` for identity
  assertion on its own. The suite runs both against the homeserver in
  `synapse/`, and asks the bridge whether each side heard the other.

### Changed

- Namespace regexes match the whole of a name rather than part of one. A
  service asks `covers?` to decide which senders are its own, and unanchored,
  `@_bridge_.*` claimed `@notours_bridge_x:localhost` as well.

- `protocol-http` is a declared dependency, since a `Service` is one of its
  middlewares.

### Removed

- `Bridge::Endpoint`, and with it Rack, the Rack env input, the `concurrency:`
  semaphore and the symbol-keyed Hashes. Events are objects a pattern reads by
  class and field together.

- `json_schemer` and the vendored registration schemas. A registration is
  validated by what it is asked for.


## [2.0.0] - 2026-10-09

A ground-up replacement of the application service API. Everything is now one
class, `Bridge::Endpoint`, driven by Ruby pattern matching, plus
`Bridge::Registration` for configuration. The Grape-and-handler-objects stack
is gone.

### Added

- `Bridge::Endpoint` — the whole AS wire protocol in one class. Built per
  request from a Rack env *or* a `Protocol::HTTP::Request`, returning the
  matching response type, so it serves a Rack stack and a bare
  `Async::HTTP::Server` equally. It also defines `to_ary` so it can be
  returned straight from a Rack router block, and `handled?` so it works as a
  router's fall-through. Events reach the matcher block as symbol-keyed
  Hashes, because Ruby hash patterns match Symbol keys only — which is what
  lets `case/in` destructure nested `content:` with no `deconstruct_keys`
  anywhere.

- Concurrent dispatch. The events of a transaction run in their own fibers
  under a bounded `Async::Semaphore` (`concurrency:`, default 8) and are all
  awaited before the response, instead of running sequentially inline. Outside
  a reactor dispatch falls back to sequential so the endpoint still works
  under `Rack::MockRequest`.

- `Bridge::Registration` — the registration file, validated against
  `registration.json` and `namespace_list.json` vendored verbatim from
  matrix-org/matrix-spec (`data/api/application-service/definitions/`). Those
  are already JSON Schema draft 2020-12. Synapse ships no schema for this file
  — it validates by hand in `synapse/config/appservice.py` — so the spec is
  the only machine-readable source. Takes `homeserver:` and `domain:` as
  required arguments and exposes `covers?`/`exclusive?` for namespaces.

### Changed

- **Namespace flattened.** `Async::Matrix::Bridge::ApplicationService::*` →
  `Async::Matrix::Bridge::*`. The three classes sit directly on `Bridge`:
  `Bridge::Endpoint`, `Bridge::Registration`, `Bridge::TransactionStore`.
  There is no sub-namespace because there is nothing to distinguish it from
  — the gem is the appservice protocol and nothing else. Bridge *domain*
  concepts (portals, ghosts, provisioning) would be new peers if they ever
  arrive, and the remote-network half of a bridge is inherently
  application-specific.

### Removed

- `Server`, `Server::Grape`, `Bot`, `Bot::Handler`, `Bot::Context`,
  `Dispatcher`, `TransactionHandler` and `Transaction`. `Bridge::Endpoint`
  replaces all of them. The `#event_types`/`#call` handler duck-type, the
  `on` DSL with its `msgtype:`/`not_from:` filters, handler registration and
  the `thirdparty` duck-type are all gone: filtering is now `case/in` with
  guards, and the long-standing `Dispatcher`/`TransactionHandler`
  double-naming is resolved by deleting both.

- `Config` and its 17-file mautrix bridgev2 JSON Schema suite.
  `Bridge::Registration` replaces it, validating the application service
  registration file against the Matrix spec's own schema. Configuration a
  registration does not describe — `database`, `encryption`, `permissions`,
  `backfill` — is no longer modelled here; `Config` remains available at the
  `v1.0.0` tag.

- Grape is no longer a dependency. `Bridge::Endpoint` speaks Rack and
  Protocol::HTTP directly.

### Fixed

- **Transactions were silently dropped.** `json_body` re-read `rack.input`
  after Grape's formatter middleware had already consumed it, and that
  middleware only rewinds when the input responds to `#rewind` — which rack 3
  streaming input (protocol-rack, so falcon and `Async::HTTP`) does not. Every
  transaction parsed as `{}` and dispatched nothing while answering `200`. It
  went unnoticed because `Rack::MockRequest` supplies a rewindable `StringIO`.

- **A failing handler lost its events permanently.** The dispatcher logged
  the exception, recorded the transaction id and returned `200`, so the
  homeserver's retry was deduplicated away. `Bridge::Endpoint` answers `500`
  and does not record the id, leaving the transaction retryable.
