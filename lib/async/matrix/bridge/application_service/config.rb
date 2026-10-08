# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix"
require "json_schemer"
require "pathname"

module Async
  module Matrix
    module Bridge
      module ApplicationService
        # A mautrix bridgev2-compatible YAML configuration file.
        #
        # Async::Matrix::Config, in the core gem, does the loading and the
        # dot-notation access; this subclass adds the bridge schema. The schema
        # mirrors the Go structs defined in mautrix/go v0.27.0
        # bridgev2/bridgeconfig — split across multiple JSON Schema files under
        # config/schema/ and composed at runtime via $ref — and runs with
        # insert_property_defaults, so a loaded config carries every documented
        # default whether or not the file spelled it out:
        #
        #   config = Config.load("bridge.yml")
        #   config.homeserver.address      # => "http://synapse:8008"
        #   config.appservice.as_token     # => "secret..."
        #   config.appservice.port         # => 29318 (schema default)
        #   config.bot_mxid                # => "@bot:localhost"
        #
        class Config < Async::Matrix::Config
          SCHEMA_DIR = Pathname.new(__dir__).join("config", "schema").freeze

          def self.schema
            @schema ||= JSONSchemer.schema(
              SCHEMA_DIR.join("config.json"),
              insert_property_defaults: true,
            )
          end

          # Overrides the core gem's no-op hook. Validation runs BEFORE the data
          # is vivified, and `insert_property_defaults` mutates `data` in place,
          # so the defaults the schema supplies are present by the time
          # Async::Matrix::Config#initialize reads it.
          def self.validate!(data)
            errors = schema.validate(data).to_a

            unless errors.empty?
              messages = errors.map { |e| e["error"] }.join("; ")
              raise Async::Matrix::BadJsonError.new(
                "M_BAD_JSON",
                "Config validation failed: #{messages}",
              )
            end
          end
        end
      end
    end
  end
end

__END__
  require "tempfile"

  describe "Async::Matrix::Bridge::ApplicationService::Config" do
    def minimal_data
      {
        "homeserver" => {
          "address" => "http://localhost:8008",
          "domain"  => "localhost"
        },
        "appservice" => {
          "as_token" => "as_secret_token_value",
          "hs_token" => "hs_secret_token_value",
          "bot"      => { "username" => "bot" }
        }
      }
    end

    it "parses a minimal valid config" do
      config = Async::Matrix::Bridge::ApplicationService::Config.new(minimal_data)
      config.homeserver.address.should == "http://localhost:8008"
      config.homeserver.domain.should == "localhost"
      config.appservice.as_token.should == "as_secret_token_value"
      config.appservice.hs_token.should == "hs_secret_token_value"
      config.appservice.bot.username.should == "bot"
    end

    it "derives bot_mxid from appservice.bot.username and homeserver.domain" do
      config = Async::Matrix::Bridge::ApplicationService::Config.new(minimal_data)
      config.bot_mxid.should == "@bot:localhost"
    end

    it "inserts property defaults from the schema" do
      config = Async::Matrix::Bridge::ApplicationService::Config.new(minimal_data)
      config.appservice.hostname.should == "0.0.0.0"
      config.appservice.port.should == 29318
      config.homeserver.software.should == "standard"
    end

    it "provides dot-notation access to deeply nested fields" do
      data = minimal_data.merge(
        "encryption" => {
          "allow" => true,
          "rotation" => { "messages" => 200 }
        }
      )
      config = Async::Matrix::Bridge::ApplicationService::Config.new(data)
      config.encryption.allow.should == true
      config.encryption.rotation.messages.should == 200
    end

    it "autovivifies missing optional sections as empty hashes" do
      config = Async::Matrix::Bridge::ApplicationService::Config.new(minimal_data)
      config.analytics.should.be.kind_of Hash
      config.analytics.should.be.empty?
    end

    it "raises BadJsonError when homeserver.address is missing" do
      data = {
        "homeserver" => { "domain" => "localhost" },
        "appservice" => { "as_token" => "a", "hs_token" => "b" }
      }
      lambda {
        Async::Matrix::Bridge::ApplicationService::Config.new(data)
      }.should.raise(Async::Matrix::BadJsonError)
    end

    it "raises BadJsonError when appservice.as_token is empty" do
      data = {
        "homeserver" => { "address" => "http://localhost:8008", "domain" => "localhost" },
        "appservice" => { "as_token" => "", "hs_token" => "b" }
      }
      lambda {
        Async::Matrix::Bridge::ApplicationService::Config.new(data)
      }.should.raise(Async::Matrix::BadJsonError)
    end

    it "raises BadJsonError for unknown top-level keys" do
      data = minimal_data.merge("bogus" => "nope")
      lambda {
        Async::Matrix::Bridge::ApplicationService::Config.new(data)
      }.should.raise(Async::Matrix::BadJsonError)
    end

    it "validates enum constraints (homeserver.software)" do
      data = minimal_data
      data["homeserver"]["software"] = "invalid_value"
      lambda {
        Async::Matrix::Bridge::ApplicationService::Config.new(data)
      }.should.raise(Async::Matrix::BadJsonError)
    end

    it "loads from a YAML file" do
      file = Tempfile.new(["config", ".yml"])
      file.write(<<~YAML)
        homeserver:
          address: "http://localhost:8008"
          domain: "localhost"
        appservice:
          as_token: "as123_secret"
          hs_token: "hs456_secret"
          bot:
            username: "testbot"
      YAML
      file.close

      config = Async::Matrix::Bridge::ApplicationService::Config.load(file.path)
      config.homeserver.address.should == "http://localhost:8008"
      config.bot_mxid.should == "@testbot:localhost"
    ensure
      file.unlink
    end

    it "raises NotFoundError for missing file" do
      lambda {
        Async::Matrix::Bridge::ApplicationService::Config.load("/nonexistent/path.yml")
      }.should.raise(Async::Matrix::NotFoundError)
    end

    it "accepts the full bridge config with permissions as string presets" do
      data = minimal_data.merge(
        "bridge" => {
          "command_prefix" => "!signal",
          "permissions" => {
            "*" => "relay",
            "localhost" => "user",
            "@admin:localhost" => "admin"
          }
        }
      )
      config = Async::Matrix::Bridge::ApplicationService::Config.new(data)
      config.bridge.command_prefix.should == "!signal"
      config.bridge.permissions[:"*"].should == "relay"
      config.bridge.permissions[:"@admin:localhost"].should == "admin"
    end
  end
