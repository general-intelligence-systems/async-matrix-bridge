# async-matrix-bridge

[![Gem Version](https://img.shields.io/gem/v/async-matrix-bridge)](https://rubygems.org/gems/async-matrix-bridge)
[![CI](https://github.com/general-intelligence-systems/async-matrix-bridge/actions/workflows/test.yaml/badge.svg)](https://github.com/general-intelligence-systems/async-matrix-bridge/actions/workflows/test.yaml)
[![License](https://img.shields.io/github/license/general-intelligence-systems/async-matrix-bridge)](https://github.com/general-intelligence-systems/async-matrix-bridge/blob/main/LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.3-red)](https://www.ruby-lang.org)

Async-native [Matrix](https://matrix.org) Application Service SDK for Ruby -- the server side of a bridge or bot. Built on [async-matrix](https://github.com/general-intelligence-systems/async-matrix) and the [Socketry](https://github.com/socketry) ecosystem (`async`, `async-http`, Falcon). No threads, no callbacks -- just fibers.

Your homeserver `PUT`s transactions of events at your service; this gem authenticates them with a constant-time token compare, deduplicates them by transaction ID, and dispatches each event to the handlers you register. Calls back to the homeserver go through async-matrix's `Client`.

## Usage

Please see the [project documentation](https://general-intelligence-systems.github.io/async-matrix-bridge/) for more details.

## Install

```ruby
gem "async-matrix-bridge"
gem "falcon"      # the async Rack server you'll run the service on
```

## Quick Start

```ruby
# config.ru
require "async/matrix/bridge"

config = Async::Matrix::Bridge::ApplicationService::Config.load("config/appservice.yml")
client = Async::Matrix::Client.new(config)

bot = Async::Matrix::Bridge::ApplicationService::Bot.new(client) do
  on "m.room.member" do |event|
    join_room(event.room_id) if event.content.membership == "invite"
  end

  on "m.room.message", msgtype: "m.text", not_from: :self do |event|
    send_notice event.room_id, "Echo: #{event.content.body}"
  end
end

app = Async::Matrix::Bridge::ApplicationService::Server.new(
  hs_token: config.appservice.hs_token,
  client:   client
) do
  dispatch bot
end

run app
```

```bash
falcon serve --bind http://0.0.0.0:9292
```

A complete working example with Docker Compose and Synapse lives in [`examples/echo_bot/`](https://github.com/general-intelligence-systems/async-matrix-bridge/tree/main/examples/echo_bot).

## Handlers

Any object that responds to `#event_types` and `#call(event)` is a handler. Use this when you need more control than the Bot DSL provides.

```ruby
class Echo
  def initialize(client) = @client = client

  def event_types = ["m.room.message"]

  def call(event)
    return unless event.content&.msgtype == "m.text"
    return unless event.sender != @client.config.bot_mxid
    @client.send_notice(event.room_id, "Echo: #{event.content.body}")
  end
end

app.dispatch(Echo.new(client))
```

Dispatch is fault-tolerant -- one handler raising won't take down the rest.

## Your own endpoints

`Server` wraps a `Grape::API` and forwards the Grape route DSL, so app-specific endpoints land on the same API as the Matrix routes. The homeserver auth filter is scoped to the Matrix routes, so your endpoints are independent of it:

```ruby
app = Async::Matrix::Bridge::ApplicationService::Server.new(
  hs_token: config.appservice.hs_token,
  client:   client
) do
  dispatch bot

  post "/_webhook/send" do
    client.send_text(params[:room_id], params[:body])
    {ok: true}
  end
end
```

`Server::Grape` is a plain mix-in, so you can skip `Server` entirely and mix the Matrix routes into your own `Grape::API`.

## Configuration

`Config` loads a mautrix bridgev2-compatible YAML file and validates it against a JSON Schema suite under `lib/async/matrix/bridge/application_service/config/schema/`, filling in every documented default:

```yaml
# config/appservice.yml
homeserver:
  address: "http://synapse:8008"
  domain: "localhost"

appservice:
  as_token: "your-appservice-token"
  hs_token: "your-homeserver-token"
  bot:
    username: "bot"
```

```ruby
config = Async::Matrix::Bridge::ApplicationService::Config.load("config/appservice.yml")
config.appservice.port   # => 29318 (schema default)
config.bot_mxid          # => "@bot:localhost"
```

You'll also need a [`registration.yml`](https://spec.matrix.org/latest/application-service-api/#registration) registered with your homeserver. See the [echo bot example](https://github.com/general-intelligence-systems/async-matrix-bridge/tree/main/examples/echo_bot) for a working template.

## Development

```bash
bin/test      # scampi, co-located `__END__` specs
bin/rubocop
```

async-matrix is an ordinary RubyGems dependency -- it resolves from RubyGems like any other gem, including inside the Nix devshell. To try a change to the core gem against this one, publish a prerelease of it, or `bundle config local` a git checkout; do not add a `path:` entry to the Gemfile. `bundlerEnv` cannot resolve a relative path source pointing outside the flake, so a path gem breaks `nix develop` outright.

## Built With

- [async-matrix](https://github.com/general-intelligence-systems/async-matrix) -- the Matrix protocol layer (client, events, media, E2EE)
- [async](https://github.com/socketry/async) -- fiber-based concurrency framework
- [grape](https://github.com/ruby-grape/grape) -- the Rack API framework the Matrix routes mix into
- [falcon](https://github.com/socketry/falcon) -- async Rack-compatible web server
- [json_schemer](https://github.com/davishmcclurg/json_schemer) -- JSON Schema validation
- [scampi](https://github.com/general-intelligence-systems/scampi) -- inline co-located test framework

## License

Apache 2.0
