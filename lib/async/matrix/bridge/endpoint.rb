# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "json"
require "uri"
require "async"
require "async/semaphore"
require "async/barrier"
require "console"

module Async
  module Matrix
    module Bridge
      class Endpoint
        PREFIX = "/_matrix/app/v1"

        JSON_HEADERS = {"content-type" => "application/json"}.freeze

        DEFAULT_CONCURRENCY = 8

        attr_reader :config, :store, :concurrency

        def initialize(config:, store: nil, concurrency: DEFAULT_CONCURRENCY, &block)
          @config = config
          @store = store
          @concurrency = concurrency
          @block = block
        end

        def call(env)
          Call.new(self, env, &@block).response
        end

        class Call
          def initialize(endpoint, env, &block)
            @endpoint = endpoint
            @block = block

            @verb = env["REQUEST_METHOD"]
            @path = env["PATH_INFO"].to_s
            @query = env["QUERY_STRING"].to_s
            @authorization = env["HTTP_AUTHORIZATION"]
            @input = env["rack.input"]
          end

          def response
            dispatch || not_found
          end

          private

            def hs_token = @endpoint.config.appservice.hs_token.to_s

            def store = @endpoint.store

            def path = @path.delete_suffix("/")

            def dispatch
              case [@verb, path]
              in ["POST", "#{Endpoint::PREFIX}/ping"]
                reply(200, {})
              in [_, String => requested] if !requested.start_with?("#{Endpoint::PREFIX}/")
                nil
              else
                authenticated { route }
              end
            end

            def route
              case [@verb, path.delete_prefix("#{Endpoint::PREFIX}/").split("/")]
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

            def transaction(txn_id)
              if store&.seen?(txn_id)
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

            def messages(body)
              Array(body[:events]) +
                Array(body[:"de.sorunome.msc2409.ephemeral"] || body[:ephemeral])
            end

            def deliver(txn_id, messages)
              Console.info(self) { "Transaction #{txn_id}: #{messages.size} event(s)" }

              failures = each_message(messages)

              if failures.empty?
                store&.mark_seen(txn_id)
                reply(200, {})
              else
                Console.error(self) do
                  "Transaction #{txn_id} failed (#{failures.size}/#{messages.size}); " \
                  "not recorded, homeserver will retry: #{failures.first.message}"
                end
                reply(500, {errcode: "M_UNKNOWN", error: failures.first.message})
              end
            end

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
                semaphore = Async::Semaphore.new(@endpoint.concurrency)
                barrier = Async::Barrier.new(parent: semaphore)

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

            def thirdparty(rest)
              case rest
              in ["protocol", protocol] then query({query: :protocol, protocol: protocol})
              in ["location"] then query({query: :locations, protocol: nil})
              in ["location", protocol] then query({query: :locations, protocol: protocol})
              in ["user"] then query({query: :users, protocol: nil})
              in ["user", protocol] then query({query: :users, protocol: protocol})
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

            def authenticated
              if token && secure_compare(token, hs_token)
                yield
              else
                reply(403, {errcode: "M_FORBIDDEN"})
              end
            end

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

            def parse_body
              parse(@input&.read)
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
              [status, JSON_HEADERS, [JSON.generate(body)]]
            end

            def not_found
              reply(404, {errcode: "M_NOT_FOUND"})
            end
        end

        private_constant :Call
      end
    end
  end
end

__END__
  require "stringio"
  require "async"

  describe "Async::Matrix::Bridge::Endpoint" do
    Endpoint = Async::Matrix::Bridge::Endpoint
    Store = Async::Matrix::Bridge::TransactionStore

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

    def env(verb, path, opts = {})
      {
        "REQUEST_METHOD" => verb,
        "PATH_INFO" => path,
        "QUERY_STRING" => opts[:query].to_s,
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

    def app(opts = {}, &block)
      Endpoint.new(config: opts.fetch(:config, config), store: opts[:store],
        concurrency: opts.fetch(:concurrency, 8), &block)
    end

    def status(env, opts = {}, &block)
      app(opts, &block).call(env).first
    end

    it "is callable with a rack env and answers a rack triplet" do
      response = app.call(env("POST", "/_matrix/app/v1/ping"))
      response.length.should == 3
      response.first.should == 200
      response.last.first.should == "{}"
    end

    it "sets a JSON content type" do
      app.call(env("POST", "/_matrix/app/v1/ping"))[1]["content-type"].should == "application/json"
    end

    it "serves many requests from one instance without leaking state between them" do
      endpoint = app(store: Store.new)
      endpoint.call(env("PUT", "/_matrix/app/v1/transactions/a", body: "{}", token: "secret")).first.should == 200
      endpoint.call(env("GET", "/_matrix/app/v1/rooms/%23a:localhost", token: "secret")).first.should == 404
      endpoint.call(env("POST", "/_matrix/app/v1/ping")).first.should == 200
    end

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

    it "answers M_BAD_JSON for a malformed body" do
      status(env("PUT", "/_matrix/app/v1/transactions/t1", body: "{nope", token: "secret")).should == 400
    end

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

    it "dedupes a repeated transaction id" do
      store = Store.new
      count = 0
      endpoint = app(store: store) { |_m| count += 1 }
      2.times do
        endpoint.call(env("PUT", "/_matrix/app/v1/transactions/dup", body: transaction(MESSAGE), token: "secret"))
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
        status(env("PUT", "/_matrix/app/v1/transactions/bound", body: transaction(*events), token: "secret"),
          concurrency: 2) do |_m|
            live += 1
            peak = live if live > peak
            Async::Task.current.sleep(0.01)
            live -= 1
          end
      end.wait
      peak.should == 2
    end

    it "keeps concurrent requests independent" do
      seen = []
      endpoint = app(store: Store.new) { |message| seen << message[:room_id] }
      Async do |task|
        tasks = ["!a:localhost", "!b:localhost", "!c:localhost"].each_with_index.map do |room, index|
          task.async do
            body = transaction(MESSAGE.merge(room_id: room))
            endpoint.call(env("PUT", "/_matrix/app/v1/transactions/i#{index}", body: body, token: "secret"))
          end
        end
        tasks.each(&:wait)
      end.wait
      seen.sort.should == ["!a:localhost", "!b:localhost", "!c:localhost"]
    end

    it "routes a third-party protocol query to the block and returns its hash" do
      endpoint = app do |message|
        case message
        in {query: :protocol, protocol:}
          {instances: [protocol]}
        else
          nil
        end
      end

      response = endpoint.call(env("GET", "/_matrix/app/v1/thirdparty/protocol/gitter", token: "secret"))
      response.first.should == 200
      JSON.parse(response.last.first).should == {"instances" => ["gitter"]}
    end

    it "answers M_NOT_FOUND when the block returns nil for a query" do
      status(env("GET", "/_matrix/app/v1/thirdparty/protocol/nope", token: "secret")) { |_m| nil }.should == 404
    end

    it "reads a body from an input that cannot be rewound" do
      seen = []
      body = transaction(MESSAGE)
      input = Object.new
      input.define_singleton_method(:read) { |*| @done ? "" : (@done = true; body) }

      e = env("PUT", "/_matrix/app/v1/transactions/stream", token: "secret")
      e["rack.input"] = input

      status(e) { |m| seen << m[:type] }.should == 200
      seen.should == ["m.room.message"]
    end
  end
