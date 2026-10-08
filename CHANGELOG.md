# Changelog

## v2.0.0

A ground-up replacement of the application service API. Everything is now one
class, `Endpoint`, driven by Ruby pattern matching, plus `Registration` for
configuration. The Grape-and-handler-objects stack is gone.

### Breaking

- **Namespace flattened.** `Async::Matrix::Bridge::ApplicationService::*` →
  `Async::Matrix::Bridge::*`. The three classes sit directly on `Bridge`:
  `Bridge::Endpoint`, `Bridge::Registration`, `Bridge::TransactionStore`. There
  is no sub-namespace because there is nothing to distinguish it from — the gem
  is the appservice protocol and nothing else. Bridge *domain* concepts
  (portals, ghosts, provisioning) would be new peers if they ever arrive, and
  the remote-network half of a bridge is inherently application-specific.

- **Removed** `Server`, `Server::Grape`, `Bot`, `Bot::Handler`, `Bot::Context`,
  `Dispatcher`, `TransactionHandler` and `Transaction`. `Endpoint` replaces all
  of them. The `#event_types`/`#call` handler duck-type, the `on` DSL with its
  `msgtype:`/`not_from:` filters, handler registration and the `thirdparty`
  duck-type are all gone: filtering is now `case/in` with guards, and the
  long-standing `Dispatcher`/`TransactionHandler` double-naming is resolved by
  deleting both.

- **Removed** `Config` and its 17-file mautrix bridgev2 JSON Schema suite.
  `Registration` replaces it, validating the application service registration
  file against the Matrix spec's own schema. Configuration a registration does
  not describe — `database`, `encryption`, `permissions`, `backfill` — is no
  longer modelled here; `Config` remains available at the `v1.0.0` tag.

- **Grape is no longer a dependency.** `Endpoint` speaks Rack and
  Protocol::HTTP directly.

### Added

- `Bridge::Endpoint` — the whole protocol in one class. Built per request
  from a Rack env *or* a `Protocol::HTTP::Request`, returning the matching
  response type, so it serves a Rack stack and a bare `Async::HTTP::Server`
  equally. Events reach a block as symbol-keyed Hashes, because Ruby hash
  patterns match Symbol keys only — which is what lets `case/in` destructure
  nested `content:` with no `deconstruct_keys` anywhere.

- Concurrent dispatch. The events of a transaction run in their own fibers
  under a bounded `Async::Semaphore` (`concurrency:`, default 8) and are all
  awaited before the response, instead of running sequentially inline.

- `Bridge::Registration` — the registration file, validated against
  `registration.json` and `namespace_list.json`, vendored verbatim from
  matrix-org/matrix-spec (`data/api/application-service/definitions/`). Those
  are already JSON Schema draft 2020-12. Synapse ships no schema for this file
  — it validates by hand in `synapse/config/appservice.py` — so the spec is the
  only machine-readable source. Exposes `covers?`/`exclusive?` for namespaces.

### Fixed

- **Transactions were silently dropped.** `json_body` re-read `rack.input`
  after Grape's formatter middleware had already consumed it, and that
  middleware only rewinds when the input responds to `#rewind` — which rack 3
  streaming input (protocol-rack, so falcon and `Async::HTTP`) does not. Every
  transaction parsed as `{}` and dispatched nothing while answering `200`. It
  went unnoticed because `Rack::MockRequest` supplies a rewindable `StringIO`.

- **A failing handler lost its events permanently.** The dispatcher logged the
  exception, recorded the transaction id and returned `200`, so the homeserver's
  retry was deduplicated away. `Endpoint` answers `500` and does not record the
  id, leaving the transaction retryable.
