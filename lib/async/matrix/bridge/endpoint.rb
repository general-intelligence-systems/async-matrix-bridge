# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "json"
require "uri"
require "protocol/http"
require "async"
require "async/semaphore"
require "async/barrier"
require "console"

module Async
  module Matrix
    module Bridge
      # One Matrix Application Service HTTP request, handled against a block.
      #
      # Built per request from a Rack env, so it holds no state of its own:
      # the idempotency store is passed in, and anything the block needs --
      # a Client, a config -- it closes over at the call site. Returns a Rack
      # response triplet, so it drops straight into a ratalada router block:
      #
      #   store = TransactionStore.new
      #
      #   Server.run do |request|
      #     Endpoint.new(request.env, config: config, store: store) do |message|
      #       case message
      #       in {type: "m.room.member", content: {membership: "invite"}, room_id:}
      #         client.join_room(room_id)
      #       in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:, sender:} if sender != bot
      #         client.send_notice(room_id, "Echo: #{body}")
      #       end
      #     end
      #   end
      #
      # The block is handed plain symbol-keyed Hashes, because Ruby's hash
      # patterns only match Symbol keys -- `in {type: "m.room.message"}` does
      # not match `{"type" => ...}`. Parsing with symbolize_names is what makes
      # `case/in` work on nested content with no deconstruct_keys anywhere.
      #
      # Events in a transaction are dispatched concurrently, bounded by
      # +concurrency+, and all of them are awaited before the response. A block
      # that raises fails the whole transaction: the response is 500 and the
      # transaction id is NOT recorded, so the homeserver retries it. That is
      # deliberate -- recording it first and answering 200 would make a failed
      # handler drop its events permanently, since the retry would dedupe away.
      class Endpoint
        PREFIX = "/_matrix/app/v1"

        JSON_HEADERS = {"content-type" => "application/json"}.freeze

        DEFAULT_CONCURRENCY = 8

        # @returns [Array] the Rack response triplet.
        attr_reader :response

        # +source+ is either a Rack env (a Hash) or a Protocol::HTTP::Request,
        # so the same endpoint serves a ratalada/Rack stack and a bare
        # Async::HTTP::Server.for block. The response type follows the source:
        # a Rack triplet for an env, a Protocol::HTTP::Response for a request.
        #
        # +config+ is duck-typed on +config.appservice.hs_token+ -- a
        # {Config} normally, but any object answering that will do, so an
        # application with its own configuration is not forced into this one.
        def initialize(source, config:, store: nil, concurrency: DEFAULT_CONCURRENCY, &block)
          @rack        = source.is_a?(::Hash)
          @config      = config
          @hs_token    = config.appservice.hs_token.to_s
          @store       = store
          @concurrency = concurrency
          @block       = block

          if @rack
            @verb          = source["REQUEST_METHOD"]
            @path          = source["PATH_INFO"].to_s
            @query         = source["QUERY_STRING"].to_s
            @authorization = source["HTTP_AUTHORIZATION"]
            @input         = source["rack.input"]
          else
            target, _, query = source.path.to_s.partition("?")

            @verb          = source.method
            @path          = target
            @query         = query
            @authorization = source.headers["authorization"]
            @input         = source.body
          end

          @response = dispatch
        end

        # Lets the instance stand in for its own Rack triplet, so the router
        # block can return `Endpoint.new(...)` directly.
        def to_ary = @response || not_found
        alias_method :to_a, :to_ary

        # The response in whichever form the source implies. Async::HTTP's
        # server block wants this; a Rack stack takes the instance directly.
        def response = @response || not_found

        attr_reader :config

        # False for a path this endpoint does not own, so it can be asked
        # rather than assumed:
        #
        #   endpoint = Endpoint.new(request.env, ...) { ... }
        #   endpoint.handled? ? endpoint : my_own_route
        #
        # Unasked, an unowned path answers 404 -- which makes the endpoint a
        # natural fall-through for a router that matches its own routes first.
        def handled? = !@response.nil?

        attr_reader :verb

        def path = @path.delete_suffix("/")

        private

          def dispatch
            case [verb, path]
            in ["POST", "#{PREFIX}/ping"]
              reply(200, {})
            in [_, String => p] if !p.start_with?("#{PREFIX}/")
              nil
            else
              authenticated { route }
            end
          end

          def route
            case [verb, path.delete_prefix("#{PREFIX}/").split("/")]
            in ["PUT", ["transactions", txn_id]]
              transaction(txn_id)
            in ["GET", ["users", _user_id]]
              reply(200, {})
            in ["GET", ["rooms", _room_alias]]
              reply(404, {errcode: "M_NOT_FOUND"})
            in ["GET", ["thirdparty", *rest]]
              thirdparty(rest)
            else
              nil
            end
          end

          # --- Transactions ---------------------------------------------

          def transaction(txn_id)
            if @store&.seen?(txn_id)
              Console.debug(self) { "Duplicate transaction #{txn_id} - skipping" }
              reply(200, {})
            else
              body = parse_body

              if body.nil?
                reply(400, {errcode: "M_BAD_JSON"})
              else
                deliver(txn_id, messages(body))
              end
            end
          end

          # Events first, then the ephemeral list under both the stable and the
          # unstable MSC2409 key.
          def messages(body)
            Array(body[:events]) +
              Array(body[:"de.sorunome.msc2409.ephemeral"] || body[:ephemeral])
          end

          def deliver(txn_id, messages)
            Console.info(self) { "Transaction #{txn_id}: #{messages.size} event(s)" }

            failures = each_message(messages)

            if failures.empty?
              @store&.mark_seen(txn_id)
              reply(200, {})
            else
              Console.error(self) do
                "Transaction #{txn_id} failed (#{failures.size}/#{messages.size}); " \
                "not recorded, homeserver will retry: #{failures.first.message}"
              end
              reply(500, {errcode: "M_UNKNOWN", error: failures.first.message})
            end
          end

          # Concurrent inside a reactor, sequential outside one, so the same
          # endpoint works under a fiber server and under Rack::MockRequest.
          def each_message(messages)
            if messages.empty?
              []
            else
              if Async::Task.current?
                concurrently(messages)
              else
                messages.filter_map { |message| failure_of(message) }
              end
            end
          end

          def concurrently(messages)
            [].tap do |failures|
              semaphore = Async::Semaphore.new(@concurrency)
              barrier   = Async::Barrier.new(parent: semaphore)

              messages.each do |message|
                barrier.async do
                  failure_of(message).then do |error|
                    if error
                      failures << error
                    end
                  end
                end
              end

              barrier.wait
            end
          end

          def failure_of(message)
            @block&.call(message)
            nil
          rescue => error
            Console.error(self) { "Handler raised #{error.class}: #{error.message}" }
            error
          end

          # --- Third-party queries --------------------------------------

          # Queries reach the same block as events, as a :query Hash, so one
          # case/in covers the whole protocol. Whatever the block returns is
          # the JSON body; nil is M_NOT_FOUND.
          def thirdparty(rest)
            case rest
            in ["protocol", protocol] then query({query: :protocol, protocol: protocol})
            in ["location"]           then query({query: :locations, protocol: nil})
            in ["location", protocol] then query({query: :locations, protocol: protocol})
            in ["user"]               then query({query: :users, protocol: nil})
            in ["user", protocol]     then query({query: :users, protocol: protocol})
            else nil
            end
          end

          def query(message)
            @block&.call(message.merge(params: params)).then do |result|
              if result.nil?
                reply(404, {errcode: "M_NOT_FOUND"})
              else
                reply(200, result)
              end
            end
          end

          # --- HTTP -----------------------------------------------------

          def authenticated
            if token && secure_compare(token, @hs_token)
              yield
            else
              reply(403, {errcode: "M_FORBIDDEN"})
            end
          end

          # Bearer scheme, or the legacy access_token query parameter.
          def token
            authorization = @authorization&.to_s

            if authorization&.start_with?("Bearer ")
              authorization.delete_prefix("Bearer ")
            else
              params["access_token"]
            end
          end

          def params
            @params ||= URI.decode_www_form(@query).to_h
          rescue ArgumentError
            {}
          end

          def secure_compare(a, b)
            if a.bytesize == b.bytesize
              a.unpack("C*").zip(b.unpack("C*")).inject(0) { |acc, (l, r)| acc | (l ^ r) }.zero?
            else
              false
            end
          end

          # Read exactly once and never rewound, which is all rack 3 streaming
          # input supports. Rack's #read takes the whole body; a
          # Protocol::HTTP body reads chunk-wise, so #join is its equivalent.
          def parse_body
            if @rack
              parse(@input&.read)
            else
              parse(@input&.join)
            end
          end

          def parse(raw)
            if raw.nil? || raw.empty?
              {}
            else
              JSON.parse(raw, symbolize_names: true)
            end
          rescue JSON::ParserError => error
            Console.error(self) { "Bad JSON in request: #{error.message}" }
            nil
          end

          def reply(status, body)
            JSON.generate(body).then do |json|
              if @rack
                [status, JSON_HEADERS, [json]]
              else
                ::Protocol::HTTP::Response[status, JSON_HEADERS, [json]]
              end
            end
          end

          def not_found
            reply(404, {errcode: "M_NOT_FOUND"})
          end
      end
    end
  end
end

__END__
  require "stringio"
  require "async"

  describe "Async::Matrix::Bridge::Endpoint" do
    Endpoint = Async::Matrix::Bridge::Endpoint
    Store    = Async::Matrix::Bridge::TransactionStore

    CONFIG = Async::Matrix::Bridge::Registration.new(
      {
        "id" => "spec",
        "url" => "http://appservice:9000",
        "as_token" => "as_secret_token_value",
        "hs_token" => "secret",
        "sender_localpart" => "bot",
        "namespaces" => {"users" => [], "aliases" => [], "rooms" => []},
      },
      homeserver: "http://localhost:8008",
      domain: "localhost"
    )

    def config = CONFIG

    # Positional opts hash (not kwargs) so the helper survives scampi's
    # nested-describe delegation, which forwards via *args.
    def env(verb, path, opts = {})
      {
        "REQUEST_METHOD" => verb,
        "PATH_INFO"      => path,
        "QUERY_STRING"   => opts[:query].to_s,
      }.tap do |e|
        if opts[:token]
          e["HTTP_AUTHORIZATION"] = "Bearer #{opts[:token]}"
        end
        if opts[:body]
          e["rack.input"] = StringIO.new(opts[:body])
        end
      end
    end

    def transaction(*events)
      JSON.generate({events: events})
    end

    MESSAGE = {
      type: "m.room.message",
      room_id: "!r:localhost",
      sender: "@alice:localhost",
      content: {msgtype: "m.text", body: "hi"},
    }.freeze

    def status(env, opts = {}, &block)
      Endpoint.new(env, config: opts.fetch(:config, config),
        store: opts[:store], &block).to_ary.first
    end

    # --- Wire protocol ---

    it "answers POST /ping with 200 and no auth" do
      status(env("POST", "/_matrix/app/v1/ping")).should == 200
    end

    it "rejects a transaction with no token" do
      status(env("PUT", "/_matrix/app/v1/transactions/t1", body: "{}")).should == 403
    end

    it "rejects a transaction with the wrong token" do
      status(env("PUT", "/_matrix/app/v1/transactions/t1", body: "{}", token: "wrong")).should == 403
    end

    it "accepts a transaction with a Bearer token" do
      status(env("PUT", "/_matrix/app/v1/transactions/t1", body: "{}", token: "secret")).should == 200
    end

    it "accepts the legacy access_token query parameter" do
      status(env("PUT", "/_matrix/app/v1/transactions/t1", body: "{}", query: "access_token=secret")).should == 200
    end

    it "answers a user query with 200 and a room alias query with 404" do
      status(env("GET", "/_matrix/app/v1/users/@a:localhost", token: "secret")).should == 200
      status(env("GET", "/_matrix/app/v1/rooms/%23a:localhost", token: "secret")).should == 404
    end

    it "answers 404 for a path it does not own" do
      status(env("GET", "/healthz")).should == 404
    end

    it "reports handled? false for a path it does not own" do
      Endpoint.new(env("GET", "/healthz"), config: config).handled?.should == false
    end

    it "reports handled? true for a Matrix route" do
      Endpoint.new(env("POST", "/_matrix/app/v1/ping"), config: config).handled?.should == true
    end

    it "answers M_BAD_JSON for a malformed body" do
      status(env("PUT", "/_matrix/app/v1/transactions/t1", body: "{nope", token: "secret")).should == 400
    end

    # --- Pattern matching ---

    it "hands the block symbol-keyed hashes so case/in matches nested content" do
      matched = []
      status(env("PUT", "/_matrix/app/v1/transactions/pm", body: transaction(MESSAGE), token: "secret")) do |message|
        case message
        in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:}
          matched << [room_id, body]
        else
          nil
        end
      end
      matched.should == [["!r:localhost", "hi"]]
    end

    it "lets a guard filter the bot's own events" do
      seen = []
      events = [MESSAGE, MESSAGE.merge(sender: "@bot:localhost")]
      status(env("PUT", "/_matrix/app/v1/transactions/guard", body: transaction(*events), token: "secret")) do |message|
        case message
        in {type: "m.room.message", sender:} if sender != "@bot:localhost"
          seen << sender
        else
          nil
        end
      end
      seen.should == ["@alice:localhost"]
    end

    it "dispatches ephemeral events under the unstable MSC2409 key" do
      seen = []
      body = JSON.generate({"de.sorunome.msc2409.ephemeral" => [{type: "m.typing"}]})
      status(env("PUT", "/_matrix/app/v1/transactions/eph", body: body, token: "secret")) do |message|
        seen << message[:type]
      end
      seen.should == ["m.typing"]
    end

    # --- Idempotency and failure ---

    it "dedupes a repeated transaction id" do
      store = Store.new
      count = 0
      2.times do
        status(env("PUT", "/_matrix/app/v1/transactions/dup", body: transaction(MESSAGE), token: "secret"),
          store: store) { |_m| count += 1 }
      end
      count.should == 1
    end

    it "answers 500 and does not record the transaction when the block raises" do
      store = Store.new
      code = status(env("PUT", "/_matrix/app/v1/transactions/boom", body: transaction(MESSAGE), token: "secret"),
        store: store) { |_m| raise "boom" }
      code.should == 500
      store.seen?("boom").should == false
    end

    # --- Concurrency ---

    it "dispatches the events of a transaction concurrently inside a reactor" do
      fibers = []
      events = Array.new(4) { MESSAGE }
      Async do
        status(env("PUT", "/_matrix/app/v1/transactions/conc", body: transaction(*events), token: "secret")) do |_m|
          fibers << Fiber.current.object_id
          Async::Task.current.sleep(0.01)
        end
      end.wait
      fibers.uniq.size.should == 4
    end

    it "bounds concurrency to the configured limit" do
      peak = 0
      live = 0
      events = Array.new(6) { MESSAGE }
      Async do
        Endpoint.new(env("PUT", "/_matrix/app/v1/transactions/bound", body: transaction(*events), token: "secret"),
          config: config, concurrency: 2) do |_m|
            live += 1
            peak = live if live > peak
            Async::Task.current.sleep(0.01)
            live -= 1
          end.to_ary
      end.wait
      peak.should == 2
    end

    # --- Third-party queries ---

    it "routes a third-party protocol query to the block and returns its hash" do
      response = Endpoint.new(env("GET", "/_matrix/app/v1/thirdparty/protocol/gitter", token: "secret"),
        config: config) do |message|
          case message
          in {query: :protocol, protocol:}
            {instances: [protocol]}
          else
            nil
          end
        end.to_ary
      response.first.should == 200
      JSON.parse(response.last.first).should == {"instances" => ["gitter"]}
    end

    it "answers M_NOT_FOUND when the block returns nil for a query" do
      status(env("GET", "/_matrix/app/v1/thirdparty/protocol/nope", token: "secret")) { |_m| nil }.should == 404
    end

    # --- Protocol::HTTP source (a bare Async::HTTP::Server, no Rack) ---

    def http_request(verb, path, opts = {})
      headers = []
      if opts[:token]
        headers << ["authorization", "Bearer #{opts[:token]}"]
      end
      body = opts[:body] && Protocol::HTTP::Body::Buffered.wrap(opts[:body])
      Protocol::HTTP::Request[verb, path, Protocol::HTTP::Headers[headers], body]
    end

    it "serves a Protocol::HTTP::Request and answers with a Protocol::HTTP::Response" do
      response = Endpoint.new(http_request("POST", "/_matrix/app/v1/ping"), config: config).response
      response.class.should == Protocol::HTTP::Response
      response.status.should == 200
    end

    it "rejects an unauthenticated Protocol::HTTP transaction" do
      request = http_request("PUT", "/_matrix/app/v1/transactions/t1", body: "{}")
      Endpoint.new(request, config: config).response.status.should == 403
    end

    it "dispatches events from a Protocol::HTTP transaction body" do
      seen = []
      request = http_request("PUT", "/_matrix/app/v1/transactions/ph", body: transaction(MESSAGE), token: "secret")
      response = Endpoint.new(request, config: config) do |message|
        case message
        in {type: "m.room.message", content: {body:}}
          seen << body
        else
          nil
        end
      end.response
      response.status.should == 200
      seen.should == ["hi"]
    end

    # Protocol::HTTP::Request#path is the request target, query string and all,
    # where a Rack env splits them across PATH_INFO and QUERY_STRING.
    it "splits the query string out of a Protocol::HTTP request target" do
      request = http_request("PUT", "/_matrix/app/v1/transactions/q1?access_token=secret", body: "{}")
      Endpoint.new(request, config: config).response.status.should == 200
    end

    it "answers 404 for a path it does not own over Protocol::HTTP" do
      response = Endpoint.new(http_request("GET", "/healthz"), config: config).response
      response.status.should == 404
    end

    # --- Streaming input ---

    # Rack 3 streaming input (protocol-rack, so falcon and Async::HTTP) has no
    # #rewind. The body is read exactly once here, which is what makes that work.
    it "reads a body from an input that cannot be rewound" do
      seen = []
      body = transaction(MESSAGE)
      input = Object.new
      input.define_singleton_method(:read) { |*| @done ? "" : (@done = true; body) }

      e = env("PUT", "/_matrix/app/v1/transactions/stream", token: "secret")
      e["rack.input"] = input

      Endpoint.new(e, config: config) { |m| seen << m[:type] }.to_ary.first.should == 200
      seen.should == ["m.room.message"]
    end
  end
