# frozen_string_literal: true

require_relative "lib/async/matrix/bridge/version"

Gem::Specification.new do |spec|
	 spec.name = "async-matrix-bridge"
	 spec.version = Async::Matrix::Bridge::VERSION
	 spec.authors = ["Nathan Kidd"]
	 spec.email = ["nathankidd@hey.com"]
	 spec.license = "Apache-2.0"

	 spec.summary = "An async-native Matrix Application Service SDK for Ruby."
	 spec.description = "The server side of a Matrix bridge or bot: one endpoint class that authenticates " \
 		"and deduplicates homeserver transactions, then hands each event to a block you pattern " \
 		"match on, concurrently. Serves a Rack env or a Protocol::HTTP::Request. Built on " \
 		"async-matrix and the Socketry async ecosystem."
	 spec.homepage = "https://github.com/general-intelligence-systems/async-matrix-bridge"

	 spec.required_ruby_version = ">= 3.3"

	 spec.metadata["homepage_uri"] = spec.homepage
	 spec.metadata["source_code_uri"] = spec.homepage
	 spec.metadata["documentation_uri"] = "https://general-intelligence-systems.github.io/async-matrix-bridge/"
	 spec.metadata["rubygems_mfa_required"] = "true"

	 spec.files = Dir["lib/**/*.rb", "lib/**/*.json", "LICENSE", "README.md"]
	 spec.require_paths = ["lib"]

	 spec.add_dependency "async", "~> 2.46"
	 spec.add_dependency "async-matrix", "~> 3.0"
	 spec.add_dependency "protocol-http", "~> 0.72"
	 spec.add_dependency "json_schemer", "~> 2.5"

  spec.add_development_dependency "scampi", "~> 1.0"
  spec.add_development_dependency "logger"
  spec.add_development_dependency "lefthook", "~> 2.2"
end
