# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix/bridge"

describe Async::Matrix::Bridge::Puppet do
  def registration
    Async::Matrix::Bridge::Registration.new(
      {
        "id"               => "spec",
        "as_token"         => "as-secret",
        "hs_token"         => "hs-secret",
        "sender_localpart" => "_spec_bot",
        "namespaces"       => {"users" => [{"exclusive" => true, "regex" => "@_spec_.*"}]},
      },
      homeserver: "http://localhost:8008",
    )
  end

  def client
    Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].new(nil)
  end

  def puppet(localpart = "_spec_alice")
    registration.puppet(client, localpart)
  end

  it "names the user it is" do
    expect(puppet.user_id).to be == "@_spec_alice:localhost"
  end

  # A localpart outside the namespaces is the caller's mistake rather than a request to make.
  it "refuses a localpart the registration does not cover" do
    expect{puppet("someone")}.to raise_exception(ArgumentError)
  end

  it "acts as itself on a device, and says when, for a send" do
    expect(puppet.on("DEV", ts: 7).reference.parameters).to be == {
      user_id: "@_spec_alice:localhost", device_id: "DEV", ts: 7,
    }
  end

  it "acts as itself on no particular device" do
    expect(puppet.client.reference.parameters).to be == {user_id: "@_spec_alice:localhost"}
  end
end
