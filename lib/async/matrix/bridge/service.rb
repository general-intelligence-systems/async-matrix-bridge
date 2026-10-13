# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "json"
require "openssl"

require "protocol/http/middleware"
require "protocol/http/response"
require "protocol/url/reference"

require "console"

require_relative "transaction"
require_relative "transaction_store"

module Async
  module Matrix
    module Bridge
      # The paths a homeserver calls, which this service answers.
      #
      # A middleware rather than a Rack application: it is the same primitive which sits below a
      # resource on the way out, pointed the other way, so it composes with everything else in the
      # stack and reads a streamed body without an adapter in between.
      class Service < ::Protocol::HTTP::Middleware
        # Where every path this service answers begins.
        PREFIX = "/_matrix/app/v1"

        JSON_HEADERS = {"content-type" => "application/json"}.freeze

        # @parameter registration [Registration] what the homeserver was told about this service.
        # @parameter version [String] the specification version to type the events as.
        # @parameter store [TransactionStore] what remembers the transactions already handled.
        # @yields {|transaction| ...}
        #   @parameter transaction [Transaction] the events the homeserver pushed.
        def initialize(registration, version: Async::Matrix::LATEST, store: TransactionStore.new, &block)
          super(::Protocol::HTTP::Middleware::NotFound)

          @registration = registration
          @version = version
          @store = store
          @block = block

          @queries = {}
        end

        # @attribute [Registration] what the homeserver was told about this service.
        attr :registration

        # Answer whether a user is one of this service's own.
        #
        # The homeserver asks before it invents them, and nothing means no.
        #
        # @yields {|user_id| ...} whether the user exists, or should be made to.
        def query_user(&block)
          @queries[:user] = block
        end

        # Answer whether a room alias is one of this service's own, creating the room if it is.
        #
        # @yields {|alias_id| ...} whether the room exists, or should be made to.
        def query_room(&block)
          @queries[:room] = block
        end

        # Answer what this service bridges to, which a client asks a homeserver and it asks here.
        #
        # @yields {|kind, rest| ...} the protocols, locations or users it was asked for.
        def query_thirdparty(&block)
          @queries[:thirdparty] = block
        end

        # @parameter request [Protocol::HTTP::Request] what the homeserver asked.
        # @returns [Protocol::HTTP::Response] what this service answers.
        def call(request)
          reference = ::Protocol::URL::Reference.parse(request.path)
          segments = reference.path.to_s.delete_prefix("#{PREFIX}/").split("/")
          parameters = self.parameters_of(reference)

          case [request.method, segments]
          # Nothing of ours, so nothing to say about it: a health check is not an unauthorised request.
          in [_, [*]] if !reference.path.to_s.start_with?("#{PREFIX}/")
            self.failure(404, "M_UNRECOGNIZED", "This service does not answer #{request.path}.")

          # Every path of ours, the ping included: a wrong token is what the ping exists to find.
          in [_, [*]] if !self.authentic?(request, parameters)
            self.failure(403, "M_FORBIDDEN", "The token does not match the registration.")

          in ["POST", ["ping"]]
            self.rendered(200, {})

          in ["PUT", ["transactions", txn_id]]
            self.transaction(request, ::Protocol::URL::Encoding.unescape(txn_id))

          in ["GET", ["users", user_id]]
            self.answered(:user, ::Protocol::URL::Encoding.unescape(user_id), parameters)

          in ["GET", ["rooms", alias_id]]
            self.answered(:room, ::Protocol::URL::Encoding.unescape(alias_id), parameters)

          in ["GET", ["thirdparty", *rest]]
            self.answered(:thirdparty, rest, parameters)

          # Which tells a homeserver that a feature is missing, rather than that this service is broken.
          else
            self.failure(404, "M_UNRECOGNIZED", "This service does not answer #{request.path}.")
          end
        end

        def inspect = "\#<#{self.class} #{@registration.id}>"

        private

          # Hand the transaction over, and say whether to send it again.
          #
          # It is not recorded until it has been handled, so a handler which raises leaves the
          # homeserver to retry rather than losing what it carried.
          #
          # @parameter request [Protocol::HTTP::Request] the request it arrived in.
          # @parameter txn_id [String] the transaction, which the homeserver numbers.
          # @returns [Protocol::HTTP::Response] the answer.
          def transaction(request, txn_id)
            case @store.seen?(txn_id)
            in true
              Console.debug(self) {"Transaction #{txn_id} was handled already."}

              self.rendered(200, {})
            in false
              transaction = Transaction.for(request, txn_id, version: @version)

              @block&.call(transaction)
              @store.mark_seen(txn_id)

              self.rendered(200, {})
            end
          rescue ::JSON::ParserError => error
            # Sending it again would carry the same bytes, so this says so rather than asking for them.
            Console.error(self, "A transaction was not JSON.", txn_id: txn_id, error: error)

            self.failure(400, "M_BAD_JSON", error.message)
          rescue => error
            # Not recorded, so the homeserver sends it again: whatever failed may not fail twice.
            Console.error(self, "A transaction was not handled.", txn_id: txn_id, error: error)

            self.failure(500, "M_UNKNOWN", error.message)
          end

          # Ask whoever registered an answer for this kind of question.
          #
          # The answer is a block rather than a lambda, so one which does not want the query string
          # may simply not take it.
          #
          # @parameter kind [Symbol] `:user`, `:room` or `:thirdparty`.
          # @parameter subject [Object] what was asked about.
          # @parameter parameters [Hash] the query string, which the third party lookups read.
          # @returns [Protocol::HTTP::Response] the answer.
          def answered(kind, subject, parameters)
            query = @queries[kind]

            case query&.call(subject, parameters)
            # Nothing answered, so this service does not claim it.
            in nil | false
              self.failure(404, "M_NOT_FOUND", "This service does not know #{subject}.")

            # A document to send back, which the third party lookups answer with.
            in Hash | Array => document
              self.rendered(200, document)

            # Anything else is a yes, and a yes carries no document.
            else
              self.rendered(200, {})
            end
          end

          # Whether the request carries the token the registration declares.
          #
          # From v1.4 it is a bearer token. Before that it was a query parameter, which a homeserver
          # may still send, and which must agree when both are there.
          #
          # @parameter request [Protocol::HTTP::Request] the request to check.
          # @parameter parameters [Hash] its query string, decoded.
          # @returns [Boolean] whether it matches.
          def authentic?(request, parameters)
            offered = [self.bearer(request), parameters["access_token"]].compact

            case offered
            in []
              false
            in [*] if offered.all?{|token| self.matches?(token)}
              true
            else
              false
            end
          end

          # @parameter request [Protocol::HTTP::Request] the request to read.
          # @returns [String | nil] the bearer token it carries.
          def bearer(request)
            case request.headers["authorization"]
            in String => authorization if authorization.start_with?("Bearer ")
              authorization.delete_prefix("Bearer ")
            else
              nil
            end
          end

          # Compared in constant time, because the comparison is what an attacker measures.
          #
          # @parameter token [String] the token offered.
          # @returns [Boolean] whether it is the one the registration declares.
          def matches?(token)
            ::OpenSSL.fixed_length_secure_compare(token, @registration.hs_token)
          rescue ArgumentError
            false
          end

          # The query string, which a reference carries as it arrived rather than decoded.
          #
          # @parameter reference [Protocol::URL::Reference] the path this request asked for.
          # @returns [Hash] its parameters, which may be none.
          def parameters_of(reference)
            case reference.query
            in String => query
              ::Protocol::URL::Encoding.decode_www_form(query)
            else
              {}
            end
          end

          # @parameter status [Integer] the status to answer with.
          # @parameter payload [Hash | Array] the document to answer with.
          # @returns [Protocol::HTTP::Response] the response.
          def rendered(status, payload)
            ::Protocol::HTTP::Response[status, JSON_HEADERS, [::JSON.generate(payload)]]
          end

          # The shape the client-server API uses, so a caller reads it the same way either side.
          #
          # @parameter status [Integer] the status to answer with.
          # @parameter errcode [String] the Matrix error code.
          # @parameter error [String] what went wrong, for a person to read.
          # @returns [Protocol::HTTP::Response] the response.
          def failure(status, errcode, error)
            self.rendered(status, {errcode: errcode, error: error})
          end
      end
    end
  end
end
