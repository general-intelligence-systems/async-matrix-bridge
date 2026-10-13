# async-matrix-bridge

[![Gem Version](https://img.shields.io/gem/v/async-matrix-bridge)](https://rubygems.org/gems/async-matrix-bridge)
[![CI](https://github.com/general-intelligence-systems/async-matrix-bridge/actions/workflows/test.yaml/badge.svg)](https://github.com/general-intelligence-systems/async-matrix-bridge/actions/workflows/test.yaml)
[![License](https://img.shields.io/github/license/general-intelligence-systems/async-matrix-bridge)](https://github.com/general-intelligence-systems/async-matrix-bridge/blob/main/LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.3-red)](https://www.ruby-lang.org)

The application service side of [Matrix](https://matrix.org), for Ruby: the half of a bridge the homeserver pushes to, built on [async-matrix](https://github.com/general-intelligence-systems/async-matrix) and so on [async-rest](https://github.com/socketry/async-rest).

A homeserver `PUT`s a transaction of events at your service. This gem authenticates it, drops a repeat of one it has already answered, types every event with async-matrix's own event classes and hands the transaction to your block. Everything the service says back to the homeserver it says through an async-matrix `Client`, as the user it is pretending to be.

```ruby
gem "async-matrix-bridge"
```

## The gem

Five classes, and nothing else:

| Class | What it is |
| --- | --- |
| `Registration` | the registration file both ends read, and the identities it permits |
| `Puppet` | one user the service may act as, with its own device |
| `Service` | a `Protocol::HTTP::Middleware` answering the application service API |
| `Transaction` | one pushed transaction, as a representation of typed events |
| `TransactionStore` | which transaction IDs have been answered already |

## Serving

`Service` is middleware rather than a Rack app, so it is the thing an `Async::HTTP::Server` serves. The block is handed a `Transaction`, and the events in it are async-matrix event objects: `case/in` reads them by class and by field together.

``` ruby
require "async/matrix/bridge"

registration = Async::Matrix::Bridge::Registration.load("registration.yaml", homeserver: "http://localhost:8008")

service = Async::Matrix::Bridge::Service.new(registration) do |transaction|
  transaction.each_room do |room_id, events|
    events.each do |event|
      case event
      in {sender:, content: Async::Matrix::Events::TextMessage(body:)}
        puts "<#{sender}> #{body}"
      else
        nil
      end
    end
  end
end

Async do
  Async::HTTP::Server.new(service, Async::HTTP::Endpoint.parse("http://0.0.0.0:9000")).run
end
```

`each_room` groups a transaction's events by the room they belong to, in the order they arrived. `events` and `ephemeral` are the two lists the specification puts in a transaction; there is no third, which matters for encryption below.

A homeserver pushes over HTTP/1.1 and will not do h2c with prior knowledge, so a listener pinned to HTTP/2 never receives anything.

The queries are three blocks rather than three routes. Each answers whether the service has something, and `nil` is `M_NOT_FOUND`:

``` ruby
service.query_user{|user_id| registration.covers?("users", user_id)}
service.query_room{|room_alias| room_alias == "#_bridge_lobby:localhost"}
```

A path outside `/_matrix/app/v1` is a `404` before anything is authenticated, so the service composes as the fall-through of a router which has its own routes.

If your block raises, the response is `500` and the transaction ID is **not** recorded, so the homeserver retries it. Recording it would make one failed handler drop those events for good.

## Acting as somebody

A service does not log in. It asserts an identity: its own token says which service, and the user is a parameter on the request. `Registration#as` is that, and `Puppet` is one user it may act as.

``` ruby
puppet = registration.puppet(client, "_bridge_ripley")

puppet.register!
puppet.device!("RIPLEY1", display_name: "ripley")

puppet.client.join_room(room_id)
puppet.on("RIPLEY1").room(room_id).send_message(content.type, content.to_h)
```

`puppet.client` is the user; `puppet.on(device_id)` is the user at one of its devices, which is what keys belong to. Both take `ts:`, which is how a bridge gives a message the time it was really said. A localpart outside the registration's namespaces is refused here rather than at the homeserver.

Every one of those is an ordinary async-matrix call on a resource derived with `#with`. This gem adds no helpers of its own for talking to the homeserver, and it has no opinion about which calls a bridge makes.

## Encryption

A transaction carries `events` and `ephemeral`, and no keys at all. So nothing pushed to a service can be decrypted by anything that push told it — and the specification is explicit about the way in: a service which wants `/sync` syncs as one of its own users.

So an encrypted bridge has two inputs which meet in one machine's store. The ciphertext is pushed, the keys are pulled, and neither input knows about the other:

- the `Service` block hands the ciphertext to the machine, which defers what it cannot read yet,
- a sync loop, running as a puppet, pulls the to-device traffic the keys arrive in, and the key releases the deferred event.

Synapse answers `/sync` for the service's own user with a `500`, so the user which reads is a puppet rather than the sender localpart. [`examples/bridge.rb`](examples/bridge.rb) is that, whole and working, in one file.

## The examples

Both examples run against the homeserver in `synapse/`, and the suite runs them:

- [`examples/bridge.rb`](examples/bridge.rb) — a bridge, both ways, between Matrix and a line protocol. A nick on the other network gets a user and a device of its own; an encrypted room is encrypted to, by claiming a key from every device and sharing a Megolm session over Olm; what Matrix says comes back out of the socket.
- [`examples/puppeting.rb`](examples/puppeting.rb) — identity assertion on its own: the service's own user, a puppet, a device, published keys, cross-signing, timestamp massaging, and the refusal of a user outside the namespaces.

``` bash
REGISTRATION=./synapse/appservice.yaml HOMESERVER=http://localhost:7400 CHANNEL=lobby ENCRYPTED=true ruby examples/bridge.rb

printf 'ripley\nhello from the network\n' | nc localhost 9100
```

## Development

``` bash
bin/test      # brings the homeserver up, then runs sus
bin/rubocop
```

`bin/test` recreates the container rather than reusing it: its database is in tmpfs, and a transaction which failed once puts the homeserver's scheduler into a backoff reaching 512 seconds, which an example started afterwards would be waiting on rather than on itself.

async-matrix is an ordinary RubyGems dependency. To try a change to it against this gem, publish a prerelease or `bundle config local` a git checkout; do not add a `path:` entry to the Gemfile, because `bundlerEnv` cannot resolve a path source pointing outside the flake and `nix develop` then fails outright.

## Built with

- [async-matrix](https://github.com/general-intelligence-systems/async-matrix) — the Matrix protocol layer: clients, events, E2EE
- [async-rest](https://github.com/socketry/async-rest) — resources and representations, which this gem's are
- [protocol-http](https://github.com/socketry/protocol-http) — the middleware a `Service` is
- [async](https://github.com/socketry/async) — fibers

## License

Apache 2.0
