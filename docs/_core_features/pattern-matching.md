---
layout: default
title: Pattern Matching
nav_order: 2
description: How events reach your block as symbol-keyed hashes, why that matters, and the pin and guard idioms that replace the old filter DSL.
---

# Pattern Matching

There is no handler object, no base class and no filter DSL. An `Endpoint` hands each message to your block and you match on it.

```ruby
Bridge::Endpoint.new(request.env, config: config, store: store) do |message|
  case message
  in {type: "m.room.member", content: {membership: "invite"}, room_id:, state_key: ^bot}
    client.join_room(room_id)
  in {type: "m.room.message", content: {msgtype: "m.text", body:}, room_id:, sender:} if sender != bot
    client.send_notice(room_id, "Echo: #{body}")
  else
    nil
  end
end
```

## Symbol keys, and why

Messages arrive as **symbol-keyed** Hashes. This is not a style choice — Ruby's hash patterns match `Symbol` keys only:

```ruby
case {"type" => "m.room.message"}
in {type: "m.room.message"} then "matched"
else "no match"           # <- this branch
end
```

Parsing the transaction with `symbolize_names: true` is what lets `case/in` destructure nested `content:` without a `deconstruct_keys` on anything. It is also why the block gets plain Hashes rather than `Async::Matrix::Event` objects.

The raw event is the Hash, so anything the spec puts in the envelope — `event_id`, `origin_server_ts`, `unsigned`, `state_key` — is matchable by name.

## Filters are syntax now

The old `msgtype:` and `not_from: :self` options are ordinary pattern features.

**Addressed to me** is a pin on a local:

```ruby
bot = config.bot_mxid

in {type: "m.room.member", content: {membership: "invite"}, state_key: ^bot}
```

**Not from me** is a guard:

```ruby
in {type: "m.room.message", content: {msgtype: "m.text", body:}, sender:} if sender != bot
```

**A message subtype** is just more pattern:

```ruby
in {type: "m.room.message", content: {msgtype: "m.image", url:}}
```

## Watch out: bindings leak

A pattern binding assigns to a local in the *enclosing* scope. In a long-lived matcher block this can clobber your own variables:

```ruby
body = File.read("payload.json")   # your local

handler = proc do |message|
  case message
  in {content: {body:}} then ...   # <- overwrites the local `body`
  end
end
```

`body`, `sender`, `room_id` and `type` are all plausible names for your own locals. Name them distinctly, or keep the matcher in its own scope.

## Ephemeral events

Typing notifications, receipts and presence arrive in the same block, from the transaction's ephemeral list — both the stable `ephemeral` key and the unstable `de.sorunome.msc2409.ephemeral` one. Set `receive_ephemeral: true` in your registration to get them.

```ruby
in {type: "m.typing", room_id:, content: {user_ids:}}
```

## Third-party queries

Protocol, location and user lookups reach the same block as a `:query` Hash, so one `case` covers the whole protocol. Whatever you return becomes the JSON body; `nil` is `M_NOT_FOUND`.

```ruby
in {query: :protocol, protocol:}
  {user_fields: ["nick"], location_fields: ["channel"], instances: []}
in {query: :users, protocol:, params:}
  [{protocol: protocol, userid: params["nick"], fields: {}}]
```

## Errors

A raising block fails the whole transaction: `500`, the id is not recorded, and the homeserver retries. If you want an event to be dropped rather than retried, handle the error yourself and return normally.

```ruby
in {type: "m.room.message", room_id:, content: {body:}}
  begin
    client.send_notice(room_id, transform(body))
  rescue Unprocessable => error
    Console.warn(self) { "skipping: #{error.message}" }
  end
```
