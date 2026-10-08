# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix"

module Async
  module Matrix
    module Bridge
    end
  end
end

# Same eager glob as the core gem: source files under lib/async/matrix/bridge/
# do not self-require, they rely on this loader for ordering plus targeted
# require_relative for the few load-time cross-file dependencies.
Dir.glob("#{__dir__}/bridge/**/*.rb").sort.each do |path|
  require path
end
