# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix"
require "async/rest/wrapper/json"

module Async
  module Matrix
    module Bridge
      # What the homeserver pushed, which is to a service what a sync batch is to a client.
      #
      # A representation is an instance of a resource at a point in time, and that is what this is:
      # the difference is that it was handed over rather than fetched, so the value is given at
      # construction and never read from a response.
      #
      # Being a representation is what makes it match: {Async::Matrix::Representation} already
      # deconstructs to its own document, so a whole transaction can be a pattern.
      class Transaction < Async::Matrix::Representation
        # Read one from a request, parsing it with the wrapper a response would have used.
        #
        # @parameter request [Protocol::HTTP::Request] the request the homeserver made.
        # @parameter txn_id [String] the transaction, which the homeserver numbers.
        # @parameter version [String] the specification version to type the events as.
        # @returns [Transaction] the transaction it carried.
        def self.for(request, txn_id, version: Async::Matrix::LATEST)
          value = ::Async::REST::Wrapper::JSON::Parser.new(request.body).join

          self.new(nil, value: value, metadata: request.headers, txn_id: txn_id, version: version)
        end

        # @parameter resource [Nil] nothing: there is no resource to fetch this again from.
        # @parameter value [Hash] the document the homeserver sent.
        # @parameter metadata [Protocol::HTTP::Headers] the headers it arrived with.
        # @parameter txn_id [String] the transaction, which the homeserver numbers.
        # @parameter version [String] the specification version to type the events as.
        def initialize(resource, value:, metadata: {}, txn_id: nil, version: Async::Matrix::LATEST)
          super(resource, value: value, metadata: metadata)

          @txn_id = txn_id
          @events = Async::Matrix::Events.registry(version)
        end

        # @attribute [String] the transaction, which makes handling it twice unnecessary.
        attr :txn_id

        # The timeline, typed as the registry describes it.
        #
        # @returns [Array(Async::Matrix::Events::Envelope)] the events.
        def events
          (self.value[:events] || []).map{|value| @events.wrap(value)}
        end

        # Read receipts, typing and presence, which arrive only when the registration asked for them.
        #
        # @returns [Array(Async::Matrix::Events::Envelope)] the events.
        def ephemeral
          (self.value[:ephemeral] || []).map{|value| @events.wrap(value)}
        end

        # @returns [Boolean] whether this transaction carried nothing at all.
        def empty?
          self.events.empty? and self.ephemeral.empty?
        end

        # The events of each room, in the order they were sent.
        #
        # Events in one room are ordered and must stay so, because a message can depend on the
        # membership before it and a key on the session before that. Different rooms are independent,
        # so a caller may handle them at the same time.
        #
        # @yields {|room_id, events| ...}
        #   @parameter room_id [String] the room.
        #   @parameter events [Array(Async::Matrix::Events::Envelope)] its events, in order.
        def each_room
          if block_given?
            self.events.group_by(&:room_id).each do |room_id, events|
              yield room_id, events
            end
          else
            to_enum(:each_room)
          end
        end

        def inspect = "\#<#{self.class} #{@txn_id} #{self.events.size} event(s)>"
      end
    end
  end
end
