# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "console"

module Async
  module Matrix
    module Bridge
      module ApplicationService
        # Routes incoming Matrix events to registered handler objects.
        #
        # Each handler declares the event types it handles via `#event_types`.
        # When an event arrives, the dispatcher finds all matching handlers
        # and calls them. Errors in one handler do not prevent others from running.
        class Dispatcher
          def initialize(txn_store: TransactionStore.new)
            @handlers  = Hash.new { |h, k| h[k] = [] }
            @txn_store = txn_store
          end

          # Register a Bot (responds to #handlers) or a plain handler (responds
          # to #event_types and #call). Bots are expanded into their handlers.
          def register(handler)
            if handler.respond_to?(:handlers)
              handler.handlers.each { |h| register(h) }
            else
              handler.event_types.each do |type|
                @handlers[type] << handler
                Console.info(self) { "Registered #{handler.class.name} for #{type}" }
              end
            end
          end

          # Idempotently process a homeserver transaction. Duplicate transaction
          # IDs (already seen) are skipped. Returns :processed or :duplicate.
          #
          # The idempotency store lives here rather than in the HTTP layer because
          # the Grape server is stateless across requests — the dispatcher is the
          # stable, long-lived object.
          def receive_transaction(txn_id, body)
            if @txn_store.seen?(txn_id)
              Console.debug(self) { "Duplicate transaction #{txn_id} — skipping" }
              :duplicate
            else
              dispatch_transaction(body)
              @txn_store.mark_seen(txn_id)
              :processed
            end
          end

          def dispatch_transaction(body)
            Transaction.new(body).then do |txn|
              txn.events.each    { |event| dispatch(event) }
              txn.ephemeral.each { |event| dispatch(event) }
            end
          end

          def dispatch(event)
            type     = event.type
            handlers = @handlers[type]

            if handlers.empty?
              Console.debug(self) { "No handler for event type: #{type}" }
            else
              handlers.each do |handler|
                begin
                  handler.call(event)
                rescue => e
                  Console.error(self) { "Handler #{handler.class.name} raised #{e.class}: #{e.message}" }
                end
              end
            end
          end

          def handler_count
            @handlers.values.flatten.size
          end
        end
      end
    end
  end
end

__END__
  describe "Async::Matrix::Bridge::ApplicationService::Dispatcher" do
    it "registers and dispatches to handlers" do
      received = []
      handler = Object.new
      handler.define_singleton_method(:event_types) { ["m.room.message"] }
      handler.define_singleton_method(:call) { |event| received << event }

      dispatcher = Async::Matrix::Bridge::ApplicationService::Dispatcher.new
      dispatcher.register(handler)
      dispatcher.handler_count.should == 1

      event = Async::Matrix::Event.new({
        "type" => "m.room.message",
        "content" => {"body" => "hi"}
      })
      dispatcher.dispatch(event)
      received.length.should == 1
      received.first.content.body.should == "hi"
    end

    it "ignores events with no matching handler" do
      dispatcher = Async::Matrix::Bridge::ApplicationService::Dispatcher.new
      event = Async::Matrix::Event.new({"type" => "m.unknown"})
      lambda { dispatcher.dispatch(event) }.should.not.raise
    end

    it "continues dispatching when a handler raises" do
      results = []
      bad_handler = Object.new
      bad_handler.define_singleton_method(:event_types) { ["m.room.message"] }
      bad_handler.define_singleton_method(:call) { |_| raise "boom" }

      good_handler = Object.new
      good_handler.define_singleton_method(:event_types) { ["m.room.message"] }
      good_handler.define_singleton_method(:call) { |e| results << e }

      dispatcher = Async::Matrix::Bridge::ApplicationService::Dispatcher.new
      dispatcher.register(bad_handler)
      dispatcher.register(good_handler)

      event = Async::Matrix::Event.new({
        "type" => "m.room.message",
        "content" => {"body" => "test"}
      })
      dispatcher.dispatch(event)
      results.length.should == 1
    end

    it "dispatches a full transaction" do
      received = []
      handler = Object.new
      handler.define_singleton_method(:event_types) { ["m.room.message"] }
      handler.define_singleton_method(:call) { |e| received << e }

      dispatcher = Async::Matrix::Bridge::ApplicationService::Dispatcher.new
      dispatcher.register(handler)

      dispatcher.dispatch_transaction({
        "events" => [
          {"type" => "m.room.message", "content" => {"body" => "one"}},
          {"type" => "m.room.message", "content" => {"body" => "two"}}
        ]
      })
      received.length.should == 2
    end

    it "registers a bot (object responding to #handlers)" do
      received = []
      handler = Object.new
      handler.define_singleton_method(:event_types) { ["m.room.message"] }
      handler.define_singleton_method(:call) { |e| received << e }

      bot = Object.new
      bot.define_singleton_method(:handlers) { [handler] }

      dispatcher = Async::Matrix::Bridge::ApplicationService::Dispatcher.new
      dispatcher.register(bot)
      dispatcher.handler_count.should == 1

      dispatcher.dispatch_transaction({
        "events" => [{"type" => "m.room.message", "content" => {"body" => "hi"}}]
      })
      received.length.should == 1
    end

    it "processes a transaction idempotently via receive_transaction" do
      received = []
      handler = Object.new
      handler.define_singleton_method(:event_types) { ["m.room.message"] }
      handler.define_singleton_method(:call) { |e| received << e }

      dispatcher = Async::Matrix::Bridge::ApplicationService::Dispatcher.new
      dispatcher.register(handler)

      body = {"events" => [{"type" => "m.room.message", "content" => {"body" => "hi"}}]}

      dispatcher.receive_transaction("txn1", body).should == :processed
      dispatcher.receive_transaction("txn1", body).should == :duplicate
      received.length.should == 1
    end
  end
