# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix/bridge"

require "protocol/http/request"
require "protocol/http/body/buffered"

describe Async::Matrix::Bridge::Service do
  MESSAGE = {
    type:             "m.room.message",
    room_id:          "!r:localhost",
    event_id:         "$1",
    sender:           "@alice:localhost",
    origin_server_ts: 1,
    content:          {msgtype: "m.text", body: "hi"},
  }.freeze

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

  def service(&block)
    subject.new(registration, &block)
  end

  def request(method, path, token: "hs-secret", body: nil)
    headers = ::Protocol::HTTP::Headers.new

    if token
      headers["authorization"] = "Bearer #{token}"
    end

    ::Protocol::HTTP::Request.new(

      "http",

      "localhost",

      method,

      path,

      nil,

      headers,
      body && ::Protocol::HTTP::Body::Buffered.new([body]),
    )
  end

  def transaction(id = "t1", events: [MESSAGE])
    request("PUT", "/_matrix/app/v1/transactions/#{id}", body: ::JSON.generate({events: events}))
  end

  it "hands the events over and says it has them" do
    seen = []
    handled = service{|t| t.each_room{|room_id, events| seen << [room_id, events.first.content.body]}}

    expect(handled.call(transaction).status).to be == 200
    expect(seen).to be == [["!r:localhost", "hi"]]
  end

  # The homeserver sends it again when its 200 was lost, so the second time is a no-op.
  it "handles a transaction once" do
    count = 0
    handled = service{|_t| count += 1}

    2.times{handled.call(transaction)}

    expect(count).to be == 1
  end

  # Not recorded, so the homeserver retries something which may not fail twice.
  it "asks for a transaction again when handling it raised" do
    handled = service{|_t| raise "nope"}

    expect(handled.call(transaction).status).to be == 500
    expect(handled.call(transaction).status).to be == 500
  end

  # Sending the same bytes again would fail the same way, so this does not ask for them.
  it "refuses a body which is not JSON" do
    asked = request("PUT", "/_matrix/app/v1/transactions/t1", body: "{nope")

    expect(service.call(asked).status).to be == 400
  end

  it "refuses a wrong token, and a missing one" do
    expect(service.call(transaction).status).to be == 200
    expect(service.call(request("PUT", "/_matrix/app/v1/transactions/t2", token: "wrong", body: "{}")).status).to be == 403
    expect(service.call(request("PUT", "/_matrix/app/v1/transactions/t3", token: nil, body: "{}")).status).to be == 403
  end

  # Which is what a homeserver sent before v1.4, and may still send alongside the header.
  it "takes the token from the query string as well" do
    asked = request("PUT", "/_matrix/app/v1/transactions/t4?access_token=hs-secret", token: nil, body: "{}")

    expect(service.call(asked).status).to be == 200
  end

  # The ping is what finds a wrong token, so it cannot be the one path which does not check.
  it "answers a ping, and refuses one carrying the wrong token" do
    expect(service.call(request("POST", "/_matrix/app/v1/ping", body: "{}")).status).to be == 200
    expect(service.call(request("POST", "/_matrix/app/v1/ping", token: "wrong", body: "{}")).status).to be == 403
  end

  it "answers for a user it claims, and not for one it does not" do
    asked = service
    asked.query_user{|user_id| registration.covers?("users", user_id)}

    expect(asked.call(request("GET", "/_matrix/app/v1/users/%40_spec_a%3Alocalhost")).status).to be == 200
    expect(asked.call(request("GET", "/_matrix/app/v1/users/%40other%3Alocalhost")).status).to be == 404
  end

  it "answers a third party query with the document it was given" do
    asked = service
    asked.query_thirdparty{|rest, _parameters| rest == ["protocols"] ? {irc: {}} : nil}

    response = asked.call(request("GET", "/_matrix/app/v1/thirdparty/protocols"))

    expect(response.status).to be == 200
    expect(response.body.join).to be == '{"irc":{}}'
  end

  it "says a path of its own is not one it knows" do
    expect(service.call(request("GET", "/_matrix/app/v1/nope")).status).to be == 404
  end

  # A health check is not an unauthorised request, so it is not answered as one.
  it "says nothing about a path which is not its own" do
    expect(service.call(request("GET", "/healthz", token: nil)).status).to be == 404
  end
end
