# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

# Gives an example a deadline, so that it can be run to the end.
#
# A bridge ends in three things which never return: `sync.each`, which is a long poll, and two accept loops, one for Matrix and one for the other network. Killing them says only that the example reached them rather than got through them.
#
# So this is required ahead of an example, by `ruby -r`, and both run against one deadline. They do what they really do until it passes, and the process then exits on its own. A room key arrives over the sync loop some time after the setup above it, so the loop has to keep going round rather than run once: that is the difference between an example which decrypts and one which only gets as far as deferring.
#
#   ruby -rfixtures/async/matrix/bridge/example_once.rb examples/bridge.rb

require "async/matrix"
require "async/matrix/e2ee"
require "async/http/server"
require "io/endpoint/generic"

module Async
  module Matrix
    module Bridge
      # How long an example runs for.
      EXAMPLE_SECONDS = Float(ENV.fetch("EXAMPLE_RUN", "30"))

      # When every loop in this example stops.
      EXAMPLE_DEADLINE = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EXAMPLE_SECONDS

      # @returns [Boolean] whether there is still time to go round again.
      def self.running?
        Process.clock_gettime(Process::CLOCK_MONOTONIC) < EXAMPLE_DEADLINE
      end

      # Sync until the deadline rather than forever.
      module SyncUntil
        # Short, so that the deadline is noticed rather than waited through.
        TIMEOUT = 1000

        # @yields {|sync| ...}
        #   @parameter sync [Async::Matrix::ClientServer::Sync] each batch.
        def each(*arguments, **options)
          if block_given?
            batch = self

            while Bridge.running?
              yield batch

              batch = batch.following(timeout: TIMEOUT)
            end
          else
            super
          end
        end
      end

      # Accept until the deadline rather than forever.
      #
      # The loop goes into a task of its own so that the deadline is something to wait for beside it. So the example's connections are served as they really are, and let go of together.
      #
      # Both of a bridge's accept loops come through here, which is why it is the endpoint they have in common rather than either of theirs: `Async::HTTP::Endpoint` and `IO::Endpoint::HostEndpoint` are each a `Generic`, and `accept` is defined once, there.
      module AcceptUntil
        # @returns [Nil] nothing, once it has stopped accepting.
        def accept(*arguments, **options, &block)
          Async do |task|
            task.async do
              super
            end

            while Bridge.running?
              task.sleep(0.1)
            end

            task.children.each(&:stop)
          end

          nil
        end
      end

      ClientServer::Sync.prepend(SyncUntil)
      ::IO::Endpoint::Generic.prepend(AcceptUntil)
    end
  end
end
