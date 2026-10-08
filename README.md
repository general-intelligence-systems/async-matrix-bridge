# async-matrix-bridge

[![Gem Version](https://img.shields.io/gem/v/async-matrix-bridge)](https://rubygems.org/gems/async-matrix-bridge)
[![CI](https://github.com/general-intelligence-systems/async-matrix-bridge/actions/workflows/test.yaml/badge.svg)](https://github.com/general-intelligence-systems/async-matrix-bridge/actions/workflows/test.yaml)
[![License](https://img.shields.io/github/license/general-intelligence-systems/async-matrix-bridge)](https://github.com/general-intelligence-systems/async-matrix-bridge/blob/main/LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.3-red)](https://www.ruby-lang.org)

Async-native [Matrix](https://matrix.org) Application Service SDK for Ruby -- the server side of a bridge or bot. Built on [async-matrix](https://github.com/general-intelligence-systems/async-matrix) and the [Socketry](https://github.com/socketry) ecosystem (`async`, `async-http`). No threads, no callbacks -- just fibers.

Your homeserver `PUT`s transactions of events at your service; this gem authenticates them with a constant-time token compare, deduplicates them by transaction ID, and hands each event to a block you pattern match on -- concurrently, in its own fiber. Calls back to the homeserver go through async-matrix's `Client`.

## Usage

Please see the [project documentation](https://general-intelligence-systems.github.io/async-matrix-bridge/) for more details.

## Install

```ruby
gem "async-matrix-bridge"
```

An `Endpoint` is not a Rack app and needs no Rack server. Add one only if you
want to run it in a Rack stack:

```ruby
gem "ratalada"        # plus protocol-rack, or falcon
gem "protocol-rack"
```

## Quick Start

The whole protocol is one class, and the events reach a block you pattern match
on. There is no handler to register, no filter DSL and no base class.

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

Working stacks with Synapse and Docker Compose live in
[`examples/`](https://github.com/general-intelligence-systems/async-matrix-bridge/tree/main/examples).

## Pattern matching

The block is handed plain **symbol-keyed** Hashes. That is deliberate: Ruby's
hash patterns match Symbol keys only, so `in {type: "m.room.message"}` would
never match a `{"type" => ...}` parsed from JSON. Parsing with
`symbolize_names` is what makes `case/in` destructure nested content with no
`deconstruct_keys` on anything.

The filters that used to be DSL options are now ordinary pattern syntax -- a
pin for "addressed to me", a guard for "not from me":

```ruby
in {type: "m.room.member", content: {membership: "invite"}, state_key: ^bot}
in {type: "m.room.message", content: {msgtype: "m.text", body:}, sender:} if sender != bot
```

Third-party protocol, location and user queries reach the same block as a
`:query` Hash, so one `case` covers the whole protocol. Whatever it returns is
the JSON body; `nil` is `M_NOT_FOUND`.

```ruby
in {query: :protocol, protocol:}
  {instances: instances_for(protocol)}
```

## Without Rack

`Endpoint` takes either a Rack env or a `Protocol::HTTP::Request`, and answers
with whichever response type the source implies. So the same class drops into a
bare `Async::HTTP::Server` with no Rack anywhere in the stack:

```ruby
server = Async::HTTP::Server.for(endpoint) do |request|
  Bridge::Endpoint.new(request, config: config, store: store) do |message|
    case message
    in {type: "m.room.message", content: {body:}, room_id:}
      client.send_notice(room_id, "Echo: #{body}")
    else
      nil
    end
  end.response
end
```

Do not pin the server to HTTP/2: homeservers push transactions over HTTP/1.1
and will not do h2c with prior knowledge, so a forced-HTTP2 listener never
receives an event.

## Your own routes

An `Endpoint` answers `404` for any path outside `/_matrix/app/v1`, so it works
as the fall-through of a router that matches its own routes first. Ask
`handled?` if you would rather compose explicitly.

```ruby
Server.run do |request|
  case request
  in ["GET", "/healthz"] then "ok\n"
  else Bridge::Endpoint.new(request.env, config: config, store: store) { |message| ... }
  end
end
```

## Concurrency and retries

The events of a transaction are dispatched in their own fibers, bounded by
`concurrency:` (default 8), and all of them are awaited before the response.

If the block raises, the response is `500` and the transaction id is **not**
recorded, so the homeserver retries it. Recording it and answering `200` would
make a failed handler drop its events permanently, since the retry would be
deduplicated away.

## Configuration

`Registration` reads the application service registration file -- the one your
homeserver already loads -- and validates it against the Matrix spec's own
schema, vendored verbatim from
[matrix-org/matrix-spec](https://github.com/matrix-org/matrix-spec/tree/main/data/api/application-service/definitions).
Nothing is restated: the tokens, the sender localpart and the namespaces are
read from the file the homeserver reads.

```yaml
# registration.yaml -- give this to your homeserver
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

```ruby
config = Bridge::Registration.load("registration.yaml",
  homeserver: "http://synapse:8008", domain: "localhost")

config.bot_mxid                              # => "@agent:localhost"
config.covers?(:users, "@alice:localhost")   # => true
config.exclusive?(:users, "@alice:localhost") # => false
```

`homeserver:` and `domain:` are separate arguments because a registration
describes the service *to* the homeserver and so cannot carry the server's own
address. `domain` is required rather than inferred from the URL: a
`server_name` need not match the host it is served from, and a wrong guess
yields plausible, broken MXIDs.

## Development

```bash
bin/test      # scampi, co-located `__END__` specs
bin/rubocop
```

async-matrix is an ordinary RubyGems dependency -- it resolves from RubyGems like any other gem, including inside the Nix devshell. To try a change to the core gem against this one, publish a prerelease of it, or `bundle config local` a git checkout; do not add a `path:` entry to the Gemfile. `bundlerEnv` cannot resolve a relative path source pointing outside the flake, so a path gem breaks `nix develop` outright.

## Built With

- [async-matrix](https://github.com/general-intelligence-systems/async-matrix) -- the Matrix protocol layer (client, events, media, E2EE)
- [async](https://github.com/socketry/async) -- fiber-based concurrency framework
- [protocol-http](https://github.com/socketry/protocol-http) -- the HTTP semantics `Endpoint` answers in
- [json_schemer](https://github.com/davishmcclurg/json_schemer) -- JSON Schema validation
- [scampi](https://github.com/general-intelligence-systems/scampi) -- inline co-located test framework

## License

Apache 2.0
