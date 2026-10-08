---
layout: default
title: Configuration
nav_order: 1
description: Registration — the appservice registration file, validated against the Matrix spec's own JSON Schema, with namespace queries.
---

# Configuration

`Bridge::Registration` reads the application service **registration file** — the same file you hand your homeserver — and validates it against the Matrix spec's own schema. There is no second config format to keep in sync.

## Loading

```ruby
Bridge = Async::Matrix::Bridge

config = Bridge::Registration.load("/config/registration.yaml",
  homeserver: "http://synapse:8008",
  domain: "localhost")
```

`Registration.new(hash, homeserver:, domain:)` takes an already-parsed Hash if you load the YAML yourself.

## Why homeserver and domain are separate

A registration describes the application service *to* the homeserver. It carries the service's own `url`, not the server's — so the homeserver address is the one thing it structurally cannot provide, and it is a required argument.

`domain` is required rather than inferred from the homeserver URL because a `server_name` need not match the host it is served from. Guessing it produces plausible, broken MXIDs, which is worse than asking.

## The file

```yaml
id: agent
url: "http://appservice:9000"
as_token: "your-appservice-token"
hs_token: "your-homeserver-token"
sender_localpart: agent
namespaces:
  users:
    - exclusive: false
      regex: "@.*:localhost"
  aliases: []
  rooms: []
```

Point your homeserver at it. In Synapse, under `app_service_config_files` in `homeserver.yaml`. Synapse reads registrations **at startup only**, so editing one needs a restart.

## Reading it

```ruby
config.id                                      # => "agent"
config.url                                     # => "http://appservice:9000"
config.sender_localpart                        # => "agent"
config.bot_mxid                                # => "@agent:localhost"

config.appservice.as_token                     # the surface Client reads
config.appservice.hs_token                     # the surface Endpoint reads
config.homeserver.address                      # => "http://synapse:8008"

config.protocols                               # => []
config.receive_ephemeral?                      # => false
config.rate_limited?                           # => false
```

That four-field surface — `homeserver.address`, `appservice.as_token`, `appservice.hs_token`, `bot_mxid` — is everything `Async::Matrix::Client` and `Endpoint` require, so one object serves both.

## Namespaces

```ruby
config.namespaces(:users)                      # the raw entries
config.covers?(:users, "@alice:localhost")     # => true
config.exclusive?(:users, "@alice:localhost")  # => false
```

`covers?` tells you whether a value falls in one of your namespaces; `exclusive?` tells you whether you claimed sole ownership of it. `:users`, `:rooms` and `:aliases` are the valid kinds; anything else raises `ArgumentError`.

## Validation

The schema lives in `lib/async/matrix/bridge/registration/schema/`, vendored verbatim from [matrix-org/matrix-spec](https://github.com/matrix-org/matrix-spec/tree/main/data/api/application-service/definitions) — `registration.yaml` and `namespace_list.yaml`, converted to JSON with the relative `$ref` repointed. They are already JSON Schema draft 2020-12, which is what `json_schemer` speaks, so they are used as published rather than transcribed.

Synapse ships no schema for this file; it validates by hand in `synapse/config/appservice.py#_load_appservice`. The spec is the only machine-readable source, and it agrees with Synapse — including the subtle rule that `url` is required *and* nullable, so push can be disabled explicitly but never by omission.

A bad file raises `Async::Matrix::BadJsonError` at load:

```ruby
Bridge::Registration.load("broken.yaml", homeserver: "http://hs", domain: "localhost")
# => Async::Matrix::BadJsonError: Registration validation failed:
#    object at root is missing required properties: hs_token
```

A missing file raises `Async::Matrix::NotFoundError`.

## Refreshing the vendored schema

The spec's definitions are the upstream source; re-fetch them and repoint the `$ref` if the spec moves:

```bash
curl -fsS https://raw.githubusercontent.com/matrix-org/matrix-spec/main/data/api/application-service/definitions/registration.yaml
curl -fsS https://raw.githubusercontent.com/matrix-org/matrix-spec/main/data/api/application-service/definitions/namespace_list.yaml
```

They must be written as `.json`: the gemspec packages `lib/**/*.json` and would silently drop a `.yaml`.
