# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix/bridge"

describe Async::Matrix::Bridge::Transaction do
  def message(room_id, body)
    {
      type:             "m.room.message",
      room_id:          room_id,
      event_id:         "$#{body}",
      sender:           "@alice:localhost",
      origin_server_ts: 1,
      content:          {msgtype: "m.text", body: body},
    }
  end

  def transaction(value)
    subject.new(nil, value: value, txn_id: "t1")
  end

  it "types the events as the registry describes them" do
    event = transaction({events: [message("!r:localhost", "hi")]}).events.first

    expect(event.content).to be_a(Async::Matrix::Events::TextMessage)
    expect(event.room_id).to be == "!r:localhost"
  end

  it "answers whether it carried anything" do
    expect(transaction({})).to be(:empty?)
    expect(transaction({events: [message("!r:localhost", "hi")]})).not.to be(:empty?)
  end

  # A message can depend on the membership before it, so one room's events keep their order.
  it "groups the events by room, in order" do
    value = {
      events: [
        message("!a:localhost", "one"), message("!b:localhost", "two"), message("!a:localhost", "three"),
      ],
    }

    grouped = transaction(value).each_room.to_a.map{|room_id, events| [room_id, events.size]}

    expect(grouped).to be == [["!a:localhost", 2], ["!b:localhost", 1]]
  end

  # Which is what lets a whole transaction be a pattern.
  it "deconstructs to the document it carried" do
    case transaction({events: [], ephemeral: [{type: "m.typing", content: {}}]})
    in {events: [], ephemeral: [_]}
      matched = true
    else
      matched = false
    end

    expect(matched).to be == true
  end
end
