# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "yaml"

require_relative "puppet"

module Async
  module Matrix
    module Bridge
      # What the homeserver was told about this service, which is also the whole of its authority.
      #
      # A service cannot register itself: one which could would claim `.*` and read everything, so an
      # administrator puts this file beside the homeserver's own configuration by hand.
      #
      # The namespaces are regexes the homeserver holds too, which is why a user outside them is
      # refused here rather than asked about: the answer is already known.
      class Registration
        KINDS = ["users", "aliases", "rooms"].freeze

        # @parameter path [String] the registration file.
        # @parameter homeserver [String] where the homeserver is.
        # @returns [Registration] the registration it describes.
        def self.load(path, homeserver:)
          self.new(::YAML.safe_load_file(path), homeserver: homeserver)
        end

        # @parameter value [Hash] the registration, as the file spells it.
        # @parameter homeserver [String] where the homeserver is.
        def initialize(value, homeserver:)
          ["id", "as_token", "hs_token", "sender_localpart"].each do |field|
            unless value[field]
              raise ArgumentError, "A registration must declare #{field}!"
            end
          end

          @value = value
          @homeserver = homeserver
          @domain = ::URI.parse(homeserver).host
        end

        # @attribute [Hash] the registration, as the file spells it.
        attr :value

        # @attribute [String] where the homeserver is.
        attr :homeserver

        # @attribute [String] the server name the users of this service belong to.
        attr :domain

        # @returns [String] what the homeserver knows this service as.
        def id = @value["id"]

        # @returns [String] the token this service authenticates to the homeserver with.
        def as_token = @value["as_token"]

        # @returns [String] the token the homeserver authenticates to this service with.
        def hs_token = @value["hs_token"]

        # @returns [String] the user an unnamed request acts as.
        def sender = "@#{@value["sender_localpart"]}:#{@domain}"

        # @returns [Boolean] whether the homeserver pushes read receipts and typing as well as events.
        def ephemeral? = @value.fetch("receive_ephemeral", false)

        # @parameter kind [String] `users`, `aliases` or `rooms`.
        # @returns [Array(Hash)] the namespaces of that kind.
        def namespaces(kind)
          unless KINDS.include?(kind)
            raise ArgumentError, "A registration has no #{kind} namespace!"
          end

          @value.dig("namespaces", kind) || []
        end

        # Whether this service is interested in something, which is the same answer the homeserver has.
        #
        # @parameter kind [String] `users`, `aliases` or `rooms`.
        # @parameter value [String] the ID or alias to ask about.
        # @returns [Boolean] whether a namespace covers it.
        def covers?(kind, value)
          self.namespaces(kind).any?{|namespace| self.class.claims?(namespace, value)}
        end

        # Whether nothing else may create this, which is what an exclusive namespace means.
        #
        # @parameter kind [String] `users`, `aliases` or `rooms`.
        # @parameter value [String] the ID or alias to ask about.
        # @returns [Boolean] whether this service owns it alone.
        def exclusive?(kind, value)
          self.namespaces(kind).any? do |namespace|
            namespace["exclusive"] and self.class.claims?(namespace, value)
          end
        end

        # Whether one namespace names this, which is the whole of it rather than part.
        #
        # Anchored because a namespace names a user rather than appears inside one: unanchored,
        # `@_bridge_.*` would claim `@notours_bridge_x:localhost` too, and a bridge asks this about
        # senders to decide what is its own.
        #
        # @parameter namespace [Hash] one entry of one kind.
        # @parameter value [String] the ID or alias to ask about.
        # @returns [Boolean] whether the regex matches all of it.
        def self.claims?(namespace, value)
          ::Regexp.new("\\A(?:#{namespace["regex"]})\\z").match?(value)
        end

        # A client which acts as this service, or as one of the users it may act as.
        #
        # Identity assertion rather than a login: the token says which service, so the user is a
        # parameter on every request. `Async::REST::Resource#with` merges it into the reference, which
        # is why this is a derived resource rather than a middleware.
        #
        # `ts` is timestamp massaging, which only a service may ask for: it says when an event really
        # happened, so a backlog carried over from another network is not stamped as now.
        #
        # @parameter client [Async::Matrix::ClientServer::Client] an unauthenticated client.
        # @parameter user_id [String | nil] the user to act as, or nil for this service's own.
        # @parameter device_id [String | nil] the device to act as, which is honoured from v1.17.
        # @parameter ts [Integer | nil] when what is sent through it happened, in milliseconds.
        # @returns [Async::Matrix::ClientServer::Client] a client which acts as them.
        def as(client, user_id = nil, device_id: nil, ts: nil)
          service = client.authenticated(self.as_token)
          parameters = {user_id: user_id, device_id: device_id, ts: ts}.compact

          case user_id
          in nil
            service.with(parameters: parameters)
          in String if self.covers?("users", user_id)
            service.with(parameters: parameters)
          in String
            raise ArgumentError, "#{user_id} is outside this service's namespaces!"
          end
        end

        # The user this service is, as something which can be given a device.
        #
        # An unnamed request acts as this user, but acting as a *device* of theirs needs one to exist:
        # a service holds keys per device, and the sender has none until it makes one.
        #
        # @parameter client [Async::Matrix::ClientServer::Client] an unauthenticated client.
        # @returns [Puppet] the user this service is.
        def bot(client)
          Puppet.new(self, client, @value["sender_localpart"])
        end

        # One of this service's users, which has to be made before it can be acted as.
        #
        # @parameter client [Async::Matrix::ClientServer::Client] an unauthenticated client.
        # @parameter localpart [String] the part of the ID which names them, without the sigil.
        # @returns [Puppet] the user, and what makes it exist.
        def puppet(client, localpart)
          Puppet.new(self, client, localpart)
        end

        def inspect = "\#<#{self.class} #{self.id}>"
      end
    end
  end
end
