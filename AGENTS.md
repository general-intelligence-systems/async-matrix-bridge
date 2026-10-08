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

**async-matrix-bridge** is an async-native Matrix Application Service SDK for Ruby (gem: `async-matrix-bridge`, version 2.0.0) — the *server* side of a Matrix bridge or bot. Built on the **async-matrix** gem and the Socketry ecosystem (`async`, `async-http`) using fibers. Licensed Apache 2.0, authored by Nathan Kidd at General Intelligence Systems.

Everything here lives under `Async::Matrix::Bridge::*`. The Matrix *protocol* layer — `Client`, `MediaClient`, `Event`, `Content`, `Schema`, `Config`, `E2EE` — is **not** in this repo: it is async-matrix (`../async-matrix`), a runtime dependency. Adding protocol-level code here is a mistake; it belongs upstream.

Requires Ruby >= 3.3. Uses Nix flake for dev environment (`.envrc` + `flake.nix`).

The gem is **three classes**: `Endpoint`, `Registration` and `TransactionStore`. If a change wants a fourth, that is a signal to re-read this section.

## Commands

### Run tests

```bash
bin/test
# or directly:
CONSOLE_LEVEL=fatal bundle exec scampi
```

Tests use **scampi** (inline co-located test framework). There is no `test/` or `spec/` directory — tests live in an `__END__` section **at the bottom of every source file** (Ruby stops parsing at `__END__`, so specs never load in production). Scampi discovers them via ripgrep (files with an `__END__` section whose tail begins with `describe`/`context`/`shared`/`it`).

Single-file runs (`scampi <file>`) are **not** supported: source files don't eagerly `require` their siblings, so a lone file can't resolve the constants its specs reference.

**Every `it` must make an assertion.** A test whose body only raises on failure registers none and scampi reports it as `MISSING`, not as a pass. For "this should be rejected", return a boolean from a helper and assert on it rather than relying on a bare `raise` in an untaken branch.

### async-matrix is a plain RubyGems dependency

Do **not** add `gem "async-matrix", path: "../async-matrix"` to the Gemfile, however convenient the sibling checkout is. `pkgs.bundlerEnv` copies the Gemfile and lockfile into the store on their own, so a relative path source resolves against the store directory (`/nix/store/async-matrix`) and pure evaluation refuses it — `nix develop` fails before any Ruby runs. Bundler hits the same wall at runtime, and pinning an absolute path makes `Gemfile.lock` machine-specific.

To test a core-gem change against this one, publish a prerelease of async-matrix, or point `bundle config local.async-matrix` at a git checkout. Then regenerate `Gemfile.lock` and `gemset.nix`.

### Lint

```bash
bin/rubocop
```

`.rubocop.yml` runs with `DisabledByDefault` and enables a hand-picked set, plus eight local cops in `cops/`. The ones that bite most often:

- `Local/ConstantMatchesPath` — every file under `lib/` must define the constant its path spells, Zeitwerk-style, so `lib/async/matrix/bridge/endpoint.rb` defines `Async::Matrix::Bridge::Endpoint`. Only the *namespace* is enforced, so nested constants are fine. `IgnorePaths` exists for genuine exceptions.
- `Local/NoConditionalAssignment` — never `x = if ...`/`x = case ...`; assign inside each branch, or extract a method.
- `Local/UseTap` — assigning an accumulator and returning it at the end should be `[].tap { |acc| ... }`.
- `Local/NoModifierIf` — no trailing `if`.

### Release

```bash
gem kit bump [major|minor|patch]  # version.rb via the .erb, then relock
gem kit changelog --write         # draft this version's entry
gem kit release                   # gate, build, push, tag
```

`gem kit` is not always on PATH in the devshell; if it is missing, edit `lib/async/matrix/bridge/version.rb` and `CHANGELOG.md` by hand.

No `bin/release-gem` or `bin/increment-version` here, unlike async-matrix: this gem is pure Ruby, so `gem kit release`'s single `gem build` + `gem push` is the whole job, and it adds gates this repo wants anyway (changelog entry present and formatted, no deprecation past its deadline, working tree committed — all before anything is built). async-matrix keeps its own script only because a native extension means a source gem *plus* a precompiled gem per platform, which `gem kit release` cannot do.

### Run an example

```bash
cd examples && docker compose up --build
```

See **Examples** below. There is no `config.ru` and no Falcon: an `Endpoint` is not a Rack app.

## Architecture

### Entry point and module loading

`lib/async/matrix/bridge.rb` requires `async/matrix` (the core gem), defines `Async::Matrix::Bridge`, and auto-requires **every `.rb` file** under `lib/async/matrix/bridge/` via `Dir.glob` — the same pattern the core gem uses. Source files don't self-require their siblings; they rely on the glob for ordering.

### The whole gem

| Class | Job |
|---|---|
| `Bridge::Endpoint` | The entire AS wire protocol, per request. Auth, dedupe, parse, dispatch, respond. |
| `Bridge::Registration` | The registration file, validated against the Matrix spec's own JSON Schema. |
| `Bridge::TransactionStore` | In-memory LRU of seen transaction IDs. |

### What depends on the core gem

| Here | Needs from async-matrix |
|---|---|
| `Bridge::Registration` | raises `Async::Matrix::BadJsonError` / `NotFoundError` |
| `Bridge::Endpoint` | nothing — it has no Matrix protocol knowledge beyond the AS routes |

`Async::Matrix::Client` reads exactly four things off a config: `homeserver.address`, `appservice.as_token`, `appservice.hs_token` (that one is `Endpoint`'s) and `bot_mxid`. `Registration` presents that surface, which is why it stands in for a config without being one. Keep that list short — it is the entire contract between this gem and the core one.

### Endpoint

Built **per request** from either a Rack env (a `Hash`) or a `Protocol::HTTP::Request`, and returns the matching response type — a Rack triplet or a `Protocol::HTTP::Response`. It also defines `to_ary`, so it can be returned straight from a Rack router block. It holds no state: the `TransactionStore` is passed in and anything else (a `Client`, the bot MXID) is closed over by the matcher block at the call site.

Routes, all under `/_matrix/app/v1`: `PUT transactions/{txnId}`, `POST ping` (**no** auth), `GET users/{userId}` (200), `GET rooms/{roomAlias}` (404), `GET thirdparty/...`. Anything else is 404, so an endpoint works as a router's fall-through; `handled?` asks rather than assumes.

Three things are easy to break here:

1. **Symbol keys.** Messages reach the block as symbol-keyed Hashes because Ruby hash patterns match `Symbol` keys only — `in {type: "x"}` never matches `{"type" => "x"}`. The `JSON.parse(..., symbolize_names: true)` is load-bearing, not a preference.
2. **The body is read exactly once.** Rack's `#read` returns the whole body; a `Protocol::HTTP` body's `#read` returns the *next chunk* and `#join` is the whole-body equivalent. Rack 3 streaming input has no `#rewind`. A second read yields `""` and silently drops every event — this is exactly the bug that shipped in 1.0 via Grape's formatter middleware, and it survived because `Rack::MockRequest` supplies a rewindable `StringIO`. Any spec covering body handling needs a non-rewindable input.
3. **Failure must stay retryable.** Events dispatch concurrently under a bounded `Async::Semaphore` (`concurrency:`, default 8) and are all awaited before responding. If any raises: respond `500` and do **not** record the transaction id. Recording it and answering `200` — what 1.0 did — makes a failed handler drop its events permanently, because the homeserver's retry is deduplicated away.

Outside a reactor, dispatch falls back to sequential so the endpoint still works under `Rack::MockRequest`.

### Registration and its schema

`Bridge::Registration` validates against `registration/schema/registration.json` and `namespace_list.json`, **vendored verbatim** from matrix-org/matrix-spec (`data/api/application-service/definitions/`). Those files are already JSON Schema draft 2020-12 — what `json_schemer` speaks — so they are used as published; only the relative `$ref` is repointed at the `.json` sibling. Passing json_schemer a `Pathname` makes it resolve that `$ref` from the file's own directory, so no custom resolver is needed.

They must be `.json`: the gemspec packages `lib/**/*.json` and would silently drop a `.yaml`.

Synapse ships **no** schema for this file — it validates by hand in `synapse/config/appservice.py#_load_appservice` — so the spec is the only machine-readable source. The two agree, including the subtle rule that `url` is required *and* nullable (present, possibly null, never missing, so push cannot be disabled by omission).

`homeserver:` and `domain:` are required arguments because a registration describes the service *to* the homeserver and cannot carry the server's own address. `domain` is not inferred from the URL: a `server_name` need not match the host it is served from, and a wrong guess yields plausible, broken MXIDs.

### Idempotency

`TransactionStore` is an in-memory LRU (capacity 1024, prunes the oldest half when full). It lives outside the endpoint because the endpoint is per request while the store must be long-lived. An id is recorded only after successful dispatch.

### What 2.0 deleted

`Server`, `Server::Grape`, `Bot`, `Bot::Handler`, `Bot::Context`, `Dispatcher`, `TransactionHandler`, `Transaction`, `Config` and its 17-file mautrix bridgev2 schema suite. Grape is no longer a dependency. The handler duck-type, the `on` DSL with `msgtype:`/`not_from:`, handler registration and the `thirdparty` duck-type are all gone — filtering is `case/in` with pins and guards.

Do not reintroduce any of it. If something genuinely needs the mautrix config shape (`database`, `encryption`, `permissions`, `backfill`), it is at the `v1.0.0` tag; adding it back here means arguing for it first.

## Examples

`examples/` holds one Docker Compose stack with two services, both the same echo bot on different servers:

- `synapse/` — throwaway Synapse: SQLite in `/tmp`, an `any_password.py` module that registers any user on first login, encryption off by default. Two registration files, one per service.
- `appservice/` — on ratalada's `async` backend. `Endpoint` returns a Rack triplet straight from the router block.
- `raw_appservice/` — a bare `Async::HTTP::Server`. Its Gemfile is one gem: no ratalada, no protocol-rack, no falcon.

Both Dockerfiles build with the **repo root** as context and copy the working tree to `/gem`, because `async-matrix-bridge` is not published — the example Gemfiles use `path: "/gem"`.

Rig gotchas, each of which has cost an afternoon:

- **Synapse rejects underscores in hostnames** (IDNA): a compose service named `raw_appservice` fails with `InvalidCodepoint U+005F`. Service names must use hyphens.
- **Synapse reads registrations at startup only.** Editing one needs a restart, and a delivery failure puts that service into exponential-backoff recovery that blocks all newer transactions until the stale one lands.
- **`docker compose restart` preserves `/tmp`** (so Synapse's DB and your logins survive); recreating the container wipes it.
- **`matrix-commander --room-create` forces encryption on** regardless of the server default, and the bot has no crypto, so nothing echoes. Create test rooms through the Client-Server API instead.
- **Do not pin the server to HTTP/2.** Homeservers push transactions over HTTP/1.1 and will not do h2c with prior knowledge, so a forced-HTTP2 listener never receives an event.
