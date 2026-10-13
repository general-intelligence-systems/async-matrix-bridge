# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "async/matrix/bridge"

describe Async::Matrix::Bridge::TransactionStore do
  let(:store) {subject.new(capacity: 4)}

  it "remembers what it was told about" do
    expect(store.seen?("t1")).to be == false

    store.mark_seen("t1")

    expect(store.seen?("t1")).to be == true
  end

  # A homeserver numbers transactions forever, so the store cannot grow with them.
  it "forgets the oldest once it is full" do
    6.times{|index| store.mark_seen("t#{index}")}

    expect(store.size).to be <= 4
    expect(store.seen?("t5")).to be == true
  end
end
