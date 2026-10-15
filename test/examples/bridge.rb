# frozen_string_literal: true

# Released under the Apache License, Version 2.0.
# Copyright, 2026, by General Intelligence Systems.

require "securerandom"
require "socket"
require "tempfile"
require "tmpdir"

require "async/matrix"
require "async/matrix/bridge"
require "async/matrix/e2ee"

# Every example, run against the homeserver in `synapse/`.
#
# The examples are where the shape of this gem is worked out before it is built, so they are the first thing to go stale when a name changes. Running them is what notices.
#
# `bridge.rb` is a bridge rather than a demonstration of one, so it is tested as one: a real user joins its room, somebody on the other network says something, and each side is asked whether it heard the other. An encrypted room, because that is the half which is hard to get right.
#
# An example which reads ends in a sync loop and a server, neither of which returns, so `fixtures/async/matrix/bridge/example_once.rb` is required ahead of it and both stop at one deadline. So an example is run to the end rather than interrupted part way.
describe "examples" do
  ROOT = File.expand_path("../..", __dir__)

  # What makes the loops stop rather than run forever.
  ONCE = File.join(
    ROOT,
    "fixtures",
    "async",
    "matrix",
    "bridge",
    "example_once.rb",
  )

  EXAMPLES = Dir.glob(File.join(ROOT, "examples", "*.rb")).sort

  # The registration the rig mounts, which is what the examples are run with.
  REGISTRATION = File.join(ROOT, "synapse", "appservice.yaml")

  HOMESERVER = ENV.fetch("MATRIX_HOMESERVER", "http://localhost:7400")

  # The port the registration names, and the one the other network connects to.
  PORT = 9000
  REMOTE_PORT = 9100

  # Long enough for a room, a puppet, a device and two messages; far short of a hang.
  RUN = 30
  TIMEOUT = 150

  MEGOLM = "m.megolm.v1.aes-sha2"

  # Run one example to the end, and say how it went.
  #
  # A failed transaction is retried on a backoff reaching 512 seconds, so nothing can be queued for
  # an example in advance: whatever it is meant to receive has to happen while it is listening. That
  # is what the block is for, and it runs once the port is open.
  def run_example(path, environment = {})
    output = Tempfile.new("example")

    # Its own process group, so that a hang can be stopped whole.
    pid = Process.spawn(
      {
        "HOMESERVER"    => HOMESERVER,
        "REGISTRATION"  => REGISTRATION,
        "PORT"          => PORT.to_s,
        "REMOTE_PORT"   => REMOTE_PORT.to_s,
        "EXAMPLE_RUN"   => RUN.to_s,
        "CONSOLE_LEVEL" => ENV.fetch("CONSOLE_LEVEL", "info"),
      }.merge(environment),
      RbConfig.ruby,
      "-I#{File.join(ROOT, "lib")}",
      "-r#{ONCE}",
      path,
      out:    output.path,
      err:    output.path,
      pgroup: true,
    )

    pushed = nil

    if block_given?
      case self.listening?(pid)
      in true
        pushed = yield
      in false
        nil
      end
    end

    status = self.wait_for(pid)

    output.rewind
    written = output.read

    # Kept, so that a run which passed can be read as well as one which did not.
    ::File.write(::File.join(::Dir.tmpdir, "#{::File.basename(path)}.log"), written)

    {status: status, output: written, pushed: pushed}.tap do
      output.close!
    end
  end

  # Whether the example got as far as serving, which is when it can be talked to.
  def listening?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    open = false
    died = false

    while !open and !died and Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      open = self.connects?(PORT) && self.connects?(REMOTE_PORT)

      unless open
        died = !Process.waitpid(pid, Process::WNOHANG).nil?

        unless died
          sleep(0.1)
        end
      end
    end

    open
  end

  # Whether anything is listening there yet.
  def connects?(port)
    ::TCPSocket.new("127.0.0.1", port).close

    true
  rescue ::SystemCallError
    false
  end

  # How the example ended, or nil if it had to be stopped.
  def wait_for(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
    finished = nil

    while finished.nil? and Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      _, finished = Process.waitpid2(pid, Process::WNOHANG)

      if finished.nil?
        sleep(0.05)
      end
    end

    if finished.nil?
      Process.kill("TERM", -Process.getpgid(pid))
      Process.waitpid(pid)
    end

    finished
  end

  # Say something from each side of the bridge, and answer with what the other side saw.
  #
  # Nothing here is a stub: the user has its own Olm account, the room is encrypted, and both
  # messages are Megolm. So each half of the answer is a round trip which really happened.
  def cycle(channel)
    said = {network: "the network says #{SecureRandom.hex(4)}", matrix: "matrix says #{SecureRandom.hex(4)}"}
    heard = {}

    Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].open(HOMESERVER) do |unauthenticated|
      alice = unauthenticated.logged_in("alice-#{SecureRandom.hex(4)}", "password")
      owner = alice.get_token_owner

      machine = Async::Matrix::E2EE::Machine.new(
        user_id:   owner.user_id,
        device_id: owner.device_id,
        crypto:    Async::Matrix::E2EE::Olm.new,
      )

      machine.crypto.generate_one_time_keys(10)
      alice.keys.upload_keys(device_keys: machine.device_keys, one_time_keys: machine.signed_one_time_keys)
      machine.crypto.published_one_time_keys!

      # In before anybody speaks: a puppet shares its session with the devices in the room, so a
      # user who joined afterwards would have nothing to read the message with.
      room_id = alice.directory.get_room_id_by_alias("#_bridge_#{channel}:localhost").room_id
      alice.join_room(room_id)

      socket = ::TCPSocket.new("127.0.0.1", REMOTE_PORT)
      socket.puts("ripley")
      socket.puts(said[:network])

      heard[:matrix] = self.decrypted(
        alice,
        machine,
        room_id,
        said[:network],
      )

      self.encrypt_to_room(
        alice,
        machine,
        room_id,
        said[:matrix],
      )

      heard[:network] = self.line_from(socket)

      socket.close
    end

    {said: said, heard: heard}
  end

  # Read the room until the puppet's message is decrypted out of it.
  def decrypted(client, machine, room_id, body)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    found = nil
    sync = client.sync(timeout: 0)

    while found.nil? and Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      machine.each_event(sync) do |event|
        case event
        in {room_id: ^room_id, sender: String => sender, content: Async::Matrix::Events::TextMessage(body: ^body)}
          found = sender
        else
          nil
        end
      end

      sync = sync.following(timeout: 2000)
    end

    found
  end

  # Share a session with every device in the room, then send through it.
  def encrypt_to_room(client, machine, room_id, body)
    members = client.room(room_id).get_joined_members_by_room.user_ids
    recipients = machine.recipients(client.keys.query_keys(members.to_h{|id| [id, []]}))
    wanted = machine.without_sessions(recipients)

    unless wanted.empty?
      machine.accept_claimed_keys(client.keys.claim_keys(wanted))
    end

    session = machine.session_for(room_id)

    messages = recipients.group_by(&:user_id).transform_values do |devices|
      devices.to_h do |device|
        [device.device_id, machine.encrypt_to_device(
          device,
          "m.room_key",
          {
            algorithm:   MEGOLM,
            room_id:     room_id,
            session_id:  session[:session_id],
            session_key: session[:session_key],
          },
        )
]
      end
    end

    client.to_device.send_to_device("m.room.encrypted", messages)

    content = machine.encrypt(room_id, Async::Matrix::Events::TextMessage.build(body: body))
    client.room(room_id).send_message(content.type, content.to_h)
  end

  # Say something in a bridge's room WITH THE KEY HELD BACK, and answer with what the router published.
  #
  # This is the race a router has to survive, made deterministic. A client shares the session before it sends -- so the session is exported here before the message that uses it, which is what keeps the message inside the part of the ratchet the export can read -- but the two deliveries take different routes, and the one the homeserver pushes to the service arrives first. Holding the `m.room_key` back is that order, on purpose.
  #
  # So the service is handed ciphertext it cannot read, keeps it, and is given the session afterwards. What is asked for is the line it publishes THEN: a service which decrypts only in the transaction defers this message and never speaks of it again.
  def raced(channel)
    said = "a stranger says #{SecureRandom.hex(4)}"
    heard = nil

    Async::Matrix::ClientServer::Client[Async::Matrix::LATEST].open(HOMESERVER) do |unauthenticated|
      alice = unauthenticated.logged_in("alice-#{SecureRandom.hex(4)}", "password")
      owner = alice.get_token_owner

      machine = Async::Matrix::E2EE::Machine.new(
        user_id:   owner.user_id,
        device_id: owner.device_id,
        crypto:    Async::Matrix::E2EE::Olm.new,
      )

      machine.crypto.generate_one_time_keys(10)
      alice.keys.upload_keys(device_keys: machine.device_keys, one_time_keys: machine.signed_one_time_keys)
      machine.crypto.published_one_time_keys!

      room_id = alice.directory.get_room_id_by_alias("#_bridge_#{channel}:localhost").room_id
      alice.join_room(room_id)

      # Whatever reads the streams, connected before anything is said so that nothing published can be missed.
      socket = ::TCPSocket.new("127.0.0.1", REMOTE_PORT)

      # Everybody's devices, and an Olm session with each: all of it before the session is exported, because this is what the export is delivered over.
      members = alice.room(room_id).get_joined_members_by_room.user_ids
      recipients = machine.recipients(alice.keys.query_keys(members.to_h{|id| [id, []]}))
      wanted = machine.without_sessions(recipients)

      unless wanted.empty?
        machine.accept_claimed_keys(alice.keys.claim_keys(wanted))
      end

      session = machine.session_for(room_id)

      content = machine.encrypt(room_id, Async::Matrix::Events::TextMessage.build(body: said))
      alice.room(room_id).send_message(content.type, content.to_h)

      # Long enough for the homeserver to have pushed it and the service to have deferred it, so that the key really is the second of the two to arrive.
      sleep(3)

      messages = recipients.group_by(&:user_id).transform_values do |devices|
        devices.to_h do |device|
          [device.device_id, machine.encrypt_to_device(
            device,
            "m.room_key",
            {
              algorithm: MEGOLM,
              room_id: room_id,
              session_id: session[:session_id],
              session_key: session[:session_key],
            },
          )
]
        end
      end

      alice.to_device.send_to_device("m.room.encrypted", messages)

      heard = self.line_from(socket)

      socket.close
    end

    {said: said, heard: heard}
  end

  # Whatever the bridge writes to the other network next, or nil if it writes nothing.
  def line_from(socket)
    case ::IO.select(
      [socket],
      nil,
      nil,
      45,
    )
    in [[::TCPSocket], _, _]
      socket.gets&.chomp
    else
      nil
    end
  end

  EXAMPLES.each do |path|
    name = File.basename(path)

    with name do
      it "runs against the homeserver" do
        # A room of its own, since a channel's room is made once and kept.
        channel = "test#{SecureRandom.hex(3)}"

        case name
        # A bridge, so both directions are asked for rather than the exit status alone.
        in "bridge.rb"
          result = self.run_example(path, {"CHANNEL" => channel, "ENCRYPTED" => "true"}){self.cycle(channel)}
        # A router, so what is asked of it is a message whose key arrives after it.
        in "routing.rb"
          result = self.run_example(path, {"CHANNEL" => channel}){self.raced(channel)}
        else
          result = self.run_example(path)
        end

        case result
        in {status: nil, output: String => output}
          raise "#{name} did not finish within #{TIMEOUT}s:\n\n#{output.lines.last(24).join}"
        in {status: Process::Status => status, output: String => output}
          # Anything but a clean exit is the example and the gem no longer agreeing.
          unless status.success?
            raise "#{name} exited #{status.exitstatus}:\n\n#{output.lines.last(24).join}"
          end

          expect(status.success?).to be == true
        end

        case result
        in {pushed: {said: Hash => said, heard: Hash => heard}}
          # Each side read what the other said, through a puppet and a Megolm session.
          expect(heard[:matrix]).to be == "@_bridge_ripley:localhost"
          expect(heard[:network]).to be(:include?, said[:matrix])

        # THE DEFERRED MESSAGE, PUBLISHED: the line came out of the sync loop replaying what the key released, on the stream named after the bridge whose room it was.
        in {pushed: {said: String => said, heard: String => heard}}
          expect(heard).to be(:start_with?, channel)
          expect(heard).to be(:include?, said)

        in {pushed: {said: String => said, heard: nil}}
          raise "routing.rb published nothing for a message whose key arrived second: #{said}"

        else
          nil
        end
      end
    end
  end
end
