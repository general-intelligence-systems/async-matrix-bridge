# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix/bridge"

describe Async::Matrix::Bridge::Registration do
  DECLARED = {
    "id"               => "spec",
    "as_token"         => "as-secret",
    "hs_token"         => "hs-secret",
    "sender_localpart" => "_spec_bot",
    "namespaces"       => {
      "users"   => [{"exclusive" => true, "regex" => "@_spec_.*"}],
      "aliases" => [{"exclusive" => false, "regex" => "#_spec_.*"}],
    },
  }.freeze

  def registration(overrides = {})
    subject.new(DECLARED.merge(overrides), homeserver: "http://localhost:8008")
  end

  def client
    Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].new(nil)
  end

  it "names the user an unnamed request acts as" do
    expect(registration.sender).to be == "@_spec_bot:localhost"
  end

  it "refuses a registration missing a token" do
    expect{registration("as_token" => nil)}.to raise_exception(ArgumentError)
  end

  it "answers what its namespaces cover" do
    expect(registration.covers?("users", "@_spec_alice:localhost")).to be == true
    expect(registration.covers?("users", "@someone:localhost")).to be == false
    expect(registration.exclusive?("aliases", "#_spec_chan:localhost")).to be == false
  end

  # Part of a name is not the name: a service asks this to decide which senders are its own.
  it "covers a whole name rather than part of one" do
    expect(registration.covers?("users", "@notours_spec_alice:localhost")).to be == false
  end

  it "refuses a namespace it has no notion of" do
    expect{registration.covers?("devices", "x")}.to raise_exception(ArgumentError)
  end

  # The token says which service, so the user is named on the request itself.
  it "names the user, the device and the time it acts for" do
    puppet = registration.as(client, "@_spec_alice:localhost", device_id: "DEV", ts: 7)

    expect(puppet.reference.parameters).to be == {user_id: "@_spec_alice:localhost", device_id: "DEV", ts: 7}
    expect(puppet.delegate).to be_a(Async::Matrix::Middleware::Authenticated)
  end

  it "names nobody when it was not asked to" do
    expect(registration.as(client).reference.parameters).to be == {}
  end

  # The namespaces are the homeserver's own test, so the answer is known without asking it.
  it "refuses a user outside its namespaces" do
    expect{registration.as(client, "@someone:localhost")}.to raise_exception(ArgumentError)
  end

  # Synapse answers 500 for `/sync` as this user, so a bridge which reads has to be a puppet.
  it "answers the user it is, as something which can be given a device" do
    expect(registration.bot(client).user_id).to be == "@_spec_bot:localhost"
  end
end
