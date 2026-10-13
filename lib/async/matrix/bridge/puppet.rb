# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

module Async
  module Matrix
    module Bridge
      # One of the service's own users, and what it takes to bring them into existence.
      #
      # A puppet is made twice over. Registering makes the user, and a homeserver refuses to act as
      # one it was never told about. Creating a device makes something which can hold keys, which
      # from v1.17 a service does itself rather than logging in for.
      class Puppet
        # The login type which says a service is asking, rather than a person with a password.
        LOGIN_TYPE = "m.login.application_service"

        # What a homeserver answers when the user is already there, which is not a failure here.
        IN_USE = "M_USER_IN_USE"

        # @parameter registration [Registration] the service this user belongs to.
        # @parameter client [Async::Matrix::ClientServer::Client] an unauthenticated client.
        # @parameter localpart [String] the part of the ID which names them, without the sigil.
        def initialize(registration, client, localpart)
          @registration = registration
          @client = client
          @localpart = localpart

          # Refused here rather than by the homeserver: the namespaces say which users this service
          # may act as, so a localpart outside them is a mistake in the caller rather than a request.
          unless registration.covers?("users", self.user_id)
            raise ArgumentError, "#{self.user_id} is outside this service's namespaces!"
          end
        end

        # @attribute [String] the part of the ID which names them.
        attr :localpart

        # @returns [String] the fully qualified ID of this user.
        def user_id = "@#{@localpart}:#{@registration.domain}"

        # A client which acts as this user, on no particular device.
        #
        # @parameter ts [Integer | nil] when what is sent through it happened, in milliseconds.
        # @returns [Async::Matrix::ClientServer::Client] the client.
        def client(ts: nil) = @registration.as(@client, self.user_id, ts: ts)

        # A client which acts as this user on one of their devices, which is what encryption needs.
        #
        # @parameter device_id [String] the device to act as.
        # @parameter ts [Integer | nil] when what is sent through it happened, in milliseconds.
        # @returns [Async::Matrix::ClientServer::Client] the client.
        def on(device_id, ts: nil) = @registration.as(@client, self.user_id, device_id: device_id, ts: ts)

        # Make the user, which is what lets the service act as them at all.
        #
        # Asking twice is not an error: a service does not remember which of its users it has made,
        # and a homeserver which already has one says so rather than failing.
        #
        # @returns [Boolean] whether this call is what made them.
        def register!
          @registration.as(@client).registration.register(username: @localpart, type: LOGIN_TYPE)

          true
        rescue Async::Matrix::RequestError => error
          unless error.errcode == IN_USE
            raise
          end

          false
        end

        # Make one of their devices, so there is something to hold keys and to act as.
        #
        # Asked as the user rather than as the device: acting as a device the homeserver has not got
        # is what this call is here to fix, so it cannot be how the call is made.
        #
        # @parameter device_id [String] the device to make.
        # @parameter display_name [String] what a user of the other network would recognise.
        # @returns [Async::Matrix::Representation] the empty response.
        def device!(device_id, display_name: @localpart)
          self.client.devices.update_device(device_id, display_name: display_name)
        end

        def inspect = "\#<#{self.class} #{self.user_id}>"
      end
    end
  end
end
