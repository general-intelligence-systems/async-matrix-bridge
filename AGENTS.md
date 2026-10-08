# AGENTS.md — async-matrix-bridge

## Ruby repos

Your bin directory should contain `bin/test` and `bin/rubocop`.
If there isn't a `.rubocop.yml`, then add the following `.rubocop.yml` spec that disables all specs and only enables a few. 

```yaml
AllCops:
  DisabledByDefault: true

  RubyInterpreters:
    - ruby

  Include:
    - '**/*.rb'
    - '.pryrc'

  Exclude:
    <% Dir.glob("#{__dir__}/*").grep_v(%r{#{__dir__}\/(app|lib)}).each do |dir| %>
    - <%= dir %>/**/*
    <% end %>
    - 'lib/templates/**/*'

Layout/IndentationConsistency:
  Enabled: true
  EnforcedStyle: indented_internal_methods

Layout/BlockEndNewline:
  Enabled: true

Layout/BeginEndAlignment:
  Enabled: true
  EnforcedStyleAlignWith: start_of_line

Layout/ElseAlignment:
  Enabled: true

Layout/DefEndAlignment:
  Enabled: true
  EnforcedStyleAlignWith: def

Layout/EmptyLinesAroundAccessModifier:
  Enabled: true
  EnforcedStyle: around
```

## Project Overview

**async-matrix-bridge** is an async-native Matrix Application Service SDK for Ruby (gem: `async-matrix-bridge`, version 1.0.0) — the *server* side of a Matrix bridge or bot. Built on the **async-matrix** gem and the Socketry ecosystem (`async`, `async-http`, Falcon) using fibers. Licensed Apache 2.0, authored by Nathan Kidd at General Intelligence Systems.

Everything here lives under `Async::Matrix::Bridge::ApplicationService::*`. The Matrix *protocol* layer — `Client`, `MediaClient`, `Event`, `Content`, `Schema`, `Config`, `E2EE` — is **not** in this repo: it is async-matrix (`../async-matrix`), a runtime dependency. Adding protocol-level code here is a mistake; it belongs upstream.

Requires Ruby >= 3.3. Uses Nix flake for dev environment (`.envrc` + `flake.nix`).

## Commands

### Run tests

```bash
bin/test
# or directly:
CONSOLE_LEVEL=fatal bundle exec scampi
```

Tests use **scampi** (inline co-located test framework). There is no `test/` or `spec/` directory — tests live in an `__END__` section **at the bottom of every source file** (Ruby stops parsing at `__END__`, so specs never load in production). Scampi discovers them via ripgrep (files with an `__END__` section whose tail begins with `describe`/`context`/`shared`/`it`).

Single-file runs (`scampi <file>`) are **not** supported: source files don't eagerly `require` their siblings, so a lone file can't resolve the constants its specs reference.

### async-matrix is a plain RubyGems dependency

Do **not** add `gem "async-matrix", path: "../async-matrix"` to the Gemfile, however convenient the sibling checkout is. `pkgs.bundlerEnv` copies the Gemfile and lockfile into the store on their own, so a relative path source resolves against the store directory (`/nix/store/async-matrix`) and pure evaluation refuses it — `nix develop` fails before any Ruby runs. Bundler hits the same wall at runtime, and pinning an absolute path makes `Gemfile.lock` machine-specific.

To test a core-gem change against this one, publish a prerelease of async-matrix, or point `bundle config local.async-matrix` at a git checkout. Then regenerate `Gemfile.lock` and `gemset.nix`.

### Lint

```bash
bin/rubocop
```

`.rubocop.yml` runs with `DisabledByDefault` and enables a hand-picked set, plus eight local cops in `cops/`. `Local/ConstantMatchesPath` is the one to know: every file under `lib/` must define the constant its path spells, Zeitwerk-style, so `lib/async/matrix/bridge/application_service/server.rb` defines `Async::Matrix::Bridge::ApplicationService::Server` and nothing else at top level.

### Release

```bash
gem kit bump [major|minor|patch]  # version.rb via the .erb, then relock
gem kit changelog --write         # draft this version's entry
gem kit release                   # gate, build, push, tag
```

No `bin/release-gem` or `bin/increment-version` here, unlike async-matrix: this gem is pure Ruby, so `gem kit release`'s single `gem build` + `gem push` is the whole job, and it adds gates this repo wants anyway (changelog entry present and formatted, no deprecation past its deadline, working tree committed — all before anything is built). async-matrix keeps its own script only because a native extension means a source gem *plus* a precompiled gem per platform, which `gem kit release` cannot do.

### Serve locally

```bash
falcon serve --bind http://0.0.0.0:9292
```

Requires a `config.ru` (see `examples/echo_bot/` for a working template).

## Architecture

### Entry point and module loading

`lib/async/matrix/bridge.rb` requires `async/matrix` (the core gem), defines `Async::Matrix::Bridge`, and auto-requires **every `.rb` file** under `lib/async/matrix/bridge/` via `Dir.glob` — the same pattern the core gem uses. Source files don't self-require their siblings; they rely on the glob for ordering. Two files require the core gem explicitly, because they need it before the glob would have run: `config.rb` (its superclass) and `transaction.rb` (`Schema.parse`).

### What depends on the core gem

| Here | Needs from async-matrix |
|---|---|
| `ApplicationService::Config` | subclasses `Async::Matrix::Config`; raises `Async::Matrix::BadJsonError` |
| `ApplicationService::Transaction` | `Async::Matrix::Schema.parse` → `Async::Matrix::Event` |
| `ApplicationService::Bot` | duck-types on a `Client` (`send_text`, `join_room`, …, `config.bot_mxid`) |
| `ApplicationService::Server` | nothing directly; passes a `client` through to handlers |

### Application Service protocol (Grape API)

`ApplicationService::Server` wraps a fresh `Grape::API` with `Server::Grape` mixed in, and forwards the Grape route DSL (`get`/`post`/`namespace`/`mount`/…) plus `call`, so it is a Rack app you can `run` directly. Routes, all under `/_matrix/app/v1`:

- `PUT  transactions/{txnId}` — receive events (authenticated, idempotent)
- `POST ping` — healthcheck (**no** auth)
- `GET  users/{userId}` — user existence query (returns 200)
- `GET  rooms/{roomAlias}` — room alias query (returns 404)
- `GET  thirdparty/...` — protocol/location/user lookups, delegated to `configuration[:thirdparty]`

Collaborators come from Grape `configuration`: `:hs_token`, `:dispatcher`, `:thirdparty`, `:client`. Because `Server::Grape` is a plain mix-in, you can skip `Server` entirely and include it in your own `Grape::API`.

**Event flow:** homeserver PUT → `authenticate!` (constant-time compare on `hs_token`) → `Dispatcher#receive_transaction` dedupes by txn ID → `Transaction` parses the body into events → each matching handler is called. A handler raising is logged and the rest still run.

### Handler duck-type

Any object with `#event_types -> Array<String>` and `#call(event)` is a handler. Two creation paths:

1. **Plain handler class** — implement the two methods directly
2. **Bot DSL** — `Bot.new(client) { on "m.room.message", msgtype: "m.text", not_from: :self do |event| ... end }` generates `Handler` objects with filter support. The `Context` inner class provides helper methods (`send_text`, `send_notice`, `join_room`, etc.)

Register with `server.dispatch(handler_or_bot)`, or `server.dispatch { on ... }` to build a Bot from the server's `client:`.

### Dispatcher vs TransactionHandler

`dispatcher.rb` and `transaction_handler.rb` are **the same class under two names** — `TransactionHandler` is a half-finished rename of `Dispatcher`, carried over from async-matrix as-is. `Server` still defaults to `Dispatcher.new`. Finishing the rename means deleting one file and updating `Server`; it is a breaking change to the public API, so it hasn't been done.

### Idempotency

`TransactionStore` is an in-memory LRU of seen transaction IDs (capacity 1024, prunes the oldest half when full). It lives on the dispatcher, not the HTTP layer, because the Grape server is stateless across requests while the dispatcher is long-lived.

### Configuration with JSON Schema validation

`ApplicationService::Config` subclasses `Async::Matrix::Config` and overrides the `.validate!` hook. The core class does the YAML loading and the `Vivify` dot-notation access; this subclass adds a 17-file JSON Schema suite under `lib/async/matrix/bridge/application_service/config/schema/` (mirrors mautrix bridgev2 Go structs), composed at runtime via `$ref`.

`json_schemer` runs with `insert_property_defaults: true`, which **mutates the hash in place** — validation therefore has to run before vivification, which is exactly where the core class calls the hook.

### Examples

`examples/` contains complete working applications with Docker Compose stacks:

- `synapse/` — shared Synapse + FluffyChat + Nginx base stack the others layer on
- `echo_bot/` — minimal echo bot, two plain handlers
- `inbound_webhook_bot/` — app-specific Grape endpoint alongside the Matrix routes
- `brute/` — AI agent bot (passes `ANTHROPIC_API_KEY`)
- `brute-steering/` — brute plus per-room memory and a steering queue
- `lindsey_and_dave/` — two bots in one stack

`examples/run_test.sh` builds every example against this working tree and smoke-tests the wire protocol in-process (no homeserver needed).
