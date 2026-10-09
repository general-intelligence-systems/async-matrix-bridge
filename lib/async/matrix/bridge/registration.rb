# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix"
require "json_schemer"
require "pathname"
require "yaml"

module Async
  module Matrix
    module Bridge
      class Registration
        SCHEMA_DIR = Pathname.new(__dir__).join("registration", "schema").freeze

        Homeserver = Struct.new(:address, :domain)

        Appservice = Struct.new(:as_token, :hs_token, :sender_localpart)

        NAMESPACES = %w[users rooms aliases].freeze

        attr_reader :raw, :homeserver, :appservice

        def self.schema
          @schema ||= JSONSchemer.schema(SCHEMA_DIR.join("registration.json"))
        end

        def self.load(path, homeserver:, domain:)
          Pathname.new(path).then do |pathname|
            unless pathname.exist?
              raise Async::Matrix::NotFoundError.new(
                "M_NOT_FOUND",
                "Registration file not found: #{pathname}",
              )
            end

            new(YAML.safe_load_file(pathname), homeserver: homeserver, domain: domain)
          end
        end

        def self.validate!(data)
          schema.validate(data).to_a.then do |errors|
            unless errors.empty?
              messages = errors.map { |error| error["error"] }.join("; ")
              raise Async::Matrix::BadJsonError.new(
                "M_BAD_JSON",
                "Registration validation failed: #{messages}",
              )
            end
          end
        end

        def initialize(data, homeserver:, domain:)
          self.class.validate!(data)

          @raw = data
          @homeserver = Homeserver.new(homeserver, domain)
          @appservice = Appservice.new(
            data["as_token"],
            data["hs_token"],
            data["sender_localpart"],
          )
        end

        def id = @raw["id"]

        def url = @raw["url"]

        def as_token = @appservice.as_token

        def hs_token = @appservice.hs_token

        def sender_localpart = @appservice.sender_localpart

        def protocols = @raw["protocols"] || []

        def rate_limited? = @raw.fetch("rate_limited", false)

        def receive_ephemeral? = @raw.fetch("receive_ephemeral", false)

        def namespaces(kind)
          unless NAMESPACES.include?(kind.to_s)
            raise ArgumentError, "unknown namespace #{kind.inspect}; expected one of #{NAMESPACES.join(", ")}"
          end

          @raw.fetch("namespaces", {}).fetch(kind.to_s, [])
        end

        def covers?(kind, value)
          namespaces(kind).any? { |entry| Regexp.new(entry["regex"]).match?(value) }
        end

        def bot_mxid = "@#{sender_localpart}:#{@homeserver.domain}"

        def exclusive?(kind, value)
          namespaces(kind).any? do |entry|
            entry["exclusive"] && Regexp.new(entry["regex"]).match?(value)
          end
        end
      end
    end
  end
end

__END__
  require "tempfile"

  describe "Async::Matrix::Bridge::Registration" do
    Registration = Async::Matrix::Bridge::Registration

    def valid_data
      {
        "id" => "agent",
        "url" => "http://appservice:9000",
        "as_token" => "as_secret",
        "hs_token" => "hs_secret",
        "sender_localpart" => "agent",
        "namespaces" => {
          "users" => [{"regex" => "@_agent_.*:localhost", "exclusive" => true}],
          "aliases" => [],
          "rooms" => [],
        },
      }
    end

    def rejected?(data)
      Registration.new(data, homeserver: "http://hs", domain: "d")
      false
    rescue Async::Matrix::BadJsonError
      true
    end

    def build(overrides = {})
      Registration.new(valid_data.merge(overrides), homeserver: "http://synapse:8008", domain: "localhost")
    end

    it "reads the spec fields off the registration" do
      registration = build
      registration.id.should == "agent"
      registration.url.should == "http://appservice:9000"
      registration.sender_localpart.should == "agent"
    end

    it "presents the config surface a Client and an Endpoint need" do
      registration = build
      registration.homeserver.address.should == "http://synapse:8008"
      registration.appservice.as_token.should == "as_secret"
      registration.appservice.hs_token.should == "hs_secret"
      registration.bot_mxid.should == "@agent:localhost"
    end

    it "derives bot_mxid from sender_localpart and the supplied domain" do
      Registration.new(valid_data, homeserver: "http://hs", domain: "example.org")
        .bot_mxid.should == "@agent:example.org"
    end

    it "requires the spec's required fields" do
      ["id", "as_token", "hs_token", "sender_localpart", "namespaces"].map do |field|
        rejected?(valid_data.reject { |k, _| k == field })
      end.should == [true, true, true, true, true]
    end

    it "requires url to be present but allows an explicit null" do
      build("url" => nil).url.should == nil

      rejected?(valid_data.reject { |k, _| k == "url" }).should == true
    end

    it "rejects a namespace entry missing regex or exclusive" do
      [{"exclusive" => true}, {"regex" => "@a:b"}].map do |entry|
        rejected?(valid_data.merge("namespaces" => {"users" => [entry]}))
      end.should == [true, true]
    end

    it "rejects a non-string id" do
      rejected?(valid_data.merge("id" => 42)).should == true
    end

    it "reports whether a value falls in a namespace" do
      registration = build
      registration.covers?(:users, "@_agent_alice:localhost").should == true
      registration.covers?(:users, "@someone:localhost").should == false
    end

    it "reports exclusivity separately from coverage" do
      registration = build("namespaces" => {"users" => [{"regex" => "@a.*:localhost", "exclusive" => false}]})
      registration.covers?(:users, "@alice:localhost").should == true
      registration.exclusive?(:users, "@alice:localhost").should == false
    end

    it "returns an empty list for an absent namespace kind" do
      build("namespaces" => {"users" => []}).namespaces(:rooms).should == []
    end

    it "raises for an unknown namespace kind" do
      error =
        begin
          build.namespaces(:widgets)
          nil
        rescue ArgumentError => e
          e
        end

      error.class.should == ArgumentError
    end

    it "defaults the spec's optional booleans to false" do
      registration = build
      registration.receive_ephemeral?.should == false
      registration.rate_limited?.should == false
      registration.protocols.should == []
    end

    it "reads receive_ephemeral when set" do
      build("receive_ephemeral" => true).receive_ephemeral?.should == true
    end

    it "loads from a YAML file" do
      file = Tempfile.new(["registration", ".yaml"])
      begin
        file.write(YAML.dump(valid_data))
        file.close

        registration = Registration.load(file.path, homeserver: "http://synapse:8008", domain: "localhost")
        registration.id.should == "agent"
        registration.bot_mxid.should == "@agent:localhost"
      ensure
        file.unlink
      end
    end

    it "raises NotFoundError for a missing file" do
      error =
        begin
          Registration.load("/nonexistent/registration.yaml", homeserver: "http://hs", domain: "d")
          nil
        rescue Async::Matrix::NotFoundError => e
          e
        end

      error.class.should == Async::Matrix::NotFoundError
    end
  end
