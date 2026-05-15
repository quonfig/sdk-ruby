# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'json'

# qfg-ryov: Process._fork hook so Puma/Unicorn workers automatically restart
# the SSE client after fork. Ruby threads do not survive fork(2), so without
# this hook a customer who initializes Quonfig in the Puma master ends up with
# workers that silently never receive SSE updates.
class TestForkSafety < Minitest::Test
  SAMPLE_PAYLOAD = '{"configs":[],"meta":{"version":"v1","environment":"test"}}'

  # Minimal SSE endpoint that sends one event per connection then FINs. The
  # SDK reconnect loop will redial; we just need to observe "the worker
  # connected at least once".
  class OneShotEndpoint < WEBrick::HTTPServlet::AbstractServlet
    @event_id = 0
    @hits = 0
    class << self
      attr_accessor :event_id, :hits
    end

    def do_GET(_request, response)
      self.class.hits += 1
      self.class.event_id += 1
      response.status = 200
      response['Content-Type'] = 'text/event-stream'
      response['Cache-Control'] = 'no-cache'
      response.chunked = false
      response.body = "id: #{self.class.event_id}\n" \
                      "data: #{TestForkSafety::SAMPLE_PAYLOAD}\n\n"
    end
  end

  def setup
    super
    OneShotEndpoint.event_id = 0
    OneShotEndpoint.hits = 0
  end

  def start_webrick_server(port, endpoint_class)
    log_string = StringIO.new
    logger = WEBrick::Log.new(log_string)
    server = WEBrick::HTTPServer.new(Port: port, Logger: logger, AccessLog: [])
    server.mount '/api/v2/sse', endpoint_class
    [server, log_string]
  end

  # Client exposes before_fork_in_parent / after_fork_in_child as part of its
  # public lifecycle API. Without these the Process._fork hook has nothing to
  # call.
  def test_client_responds_to_fork_lifecycle_hooks
    client = build_client_for_fork_tests
    begin
      assert_respond_to client, :before_fork_in_parent
      assert_respond_to client, :after_fork_in_child
    ensure
      client.stop
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # before_fork_in_parent must close the SSE worker thread (otherwise the
  # parent and child would share a Net::HTTP socket fd post-fork — both reads
  # corrupt). Idempotent: calling twice must not raise.
  def test_before_fork_in_parent_closes_sse_worker
    server, = start_webrick_server(4691, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: 4691)
    begin
      wait_for -> { client.connection_state == :connected }, max_wait: 5
      sse = client.instance_variable_get(:@sse_client)
      worker = sse.instance_variable_get(:@worker)
      assert worker&.alive?, 'expected SSE worker thread to be alive before fork'

      client.before_fork_in_parent
      client.before_fork_in_parent # idempotent

      refute worker.alive?, 'before_fork_in_parent must close the existing SSE worker'
      assert_nil client.instance_variable_get(:@sse_client),
                 'before_fork_in_parent must drop the SSE client reference'
    ensure
      client.stop
      server.stop
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # after_fork_in_child must replace the (dead, fork-inherited) SSE worker
  # with a brand-new thread that successfully connects. The new worker must
  # be a *different* Thread object than the parent's pre-fork worker — that's
  # the only mechanical way to know the child isn't still holding a dead
  # reference.
  def test_after_fork_in_child_starts_a_fresh_sse_worker
    server, = start_webrick_server(4692, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: 4692)
    begin
      wait_for -> { client.connection_state == :connected }, max_wait: 5
      original_sse = client.instance_variable_get(:@sse_client)
      original_worker = original_sse.instance_variable_get(:@worker)

      # Simulate the fork lifecycle in a single process. The Process._fork
      # hook calls these in this order: before (in parent's view, pre-fork),
      # then after (in child's view, post-fork).
      client.before_fork_in_parent
      client.after_fork_in_child

      new_sse = client.instance_variable_get(:@sse_client)
      new_worker = new_sse&.instance_variable_get(:@worker)

      refute_nil new_sse, 'after_fork_in_child must reconstruct the SSE client'
      refute_same original_sse, new_sse,
                  'after_fork_in_child must allocate a fresh SSE client (not reuse the parent object)'
      refute_same original_worker, new_worker,
                  'after_fork_in_child must allocate a fresh worker thread'
      assert new_worker.alive?, 'fresh SSE worker thread must be alive'

      # connection_state alone is unreliable here: @last_successful_refresh
      # was stamped by the parent's pre-fork session, so the aggregate
      # already reads :connected even if the new worker hasn't dialed yet.
      # Wait on the WEBrick hit counter directly — that only advances when
      # the new worker actually opens a fresh TCP connection.
      wait_for -> { OneShotEndpoint.hits >= 2 }, max_wait: 5
      assert OneShotEndpoint.hits >= 2,
             "expected post-fork worker to dial the SSE server (hits=#{OneShotEndpoint.hits})"
    ensure
      client.stop
      server.stop
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # If the customer explicitly stopped the client, after_fork_in_child must
  # NOT resurrect threads — that would silently undo `stop` after a fork.
  def test_after_fork_in_child_is_a_noop_when_stopped
    server, = start_webrick_server(4693, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: 4693)
    client.stop

    client.before_fork_in_parent
    client.after_fork_in_child

    assert_nil client.instance_variable_get(:@sse_client),
               'after_fork_in_child must not start SSE on a stopped client'
  ensure
    server.stop
    assert_logged([/Initialization did not complete cleanly/])
  end

  # The Process._fork hook (Ruby 3.1+) must be installed at load time on
  # Process.singleton_class so any Process.fork / Kernel#fork goes through
  # our before/after lifecycle without customer wiring.
  def test_process_fork_hook_is_installed_on_supported_rubies
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    assert defined?(Quonfig::ForkSafety),
           'Quonfig::ForkSafety must be defined so Process._fork can be overridden'
    assert Process.singleton_class.include?(Quonfig::ForkSafety),
           'Quonfig::ForkSafety must be prepended into Process.singleton_class to override _fork'
  end

  # End-to-end check: an actual Process.fork must produce a child whose SSE
  # worker is a different Thread than the parent's, and the child must
  # successfully receive an event from the SSE server. We use a pipe to
  # ferry "child saw an event" + "child worker object_id" back to the
  # parent for assertion.
  def test_actual_process_fork_restarts_sse_in_child
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(4694, OneShotEndpoint)
    server_thread = Thread.new { server.start }

    client = build_client_for_fork_tests(port: 4694)

    begin
      wait_for -> { client.connection_state == :connected }, max_wait: 5

      parent_worker = client.instance_variable_get(:@sse_client)
                            .instance_variable_get(:@worker)
      parent_worker_id = parent_worker.object_id

      read_io, write_io = IO.pipe

      pid = Process.fork do
        read_io.close
        begin
          # Give the post-fork hook + reconnect a moment.
          deadline = Time.now + 5
          got_envelope = false
          child_worker_id = nil

          until Time.now > deadline
            sse = client.instance_variable_get(:@sse_client)
            worker = sse&.instance_variable_get(:@worker)
            child_worker_id = worker&.object_id
            if client.connection_state == :connected && child_worker_id && child_worker_id != parent_worker_id
              got_envelope = true
              break
            end
            sleep 0.1
          end

          payload = {
            got_envelope: got_envelope,
            child_worker_id: child_worker_id,
            parent_worker_id_seen_in_child: parent_worker_id,
            connection_state: client.connection_state.to_s
          }
          write_io.write(JSON.dump(payload))
        rescue StandardError => e
          write_io.write(JSON.dump(error: "#{e.class}: #{e.message}"))
        ensure
          write_io.close
          # Exit without running parent's at_exit (which would re-run Minitest).
          exit!(0)
        end
      end

      write_io.close
      child_report = read_io.read
      read_io.close
      Process.waitpid(pid)

      refute_empty child_report, 'child wrote nothing to the pipe — likely crashed before reporting'
      report = JSON.parse(child_report)
      refute report['error'], "child errored: #{report['error']}"
      assert report['got_envelope'],
             "child did not see a post-fork SSE connection: #{report.inspect}"
      refute_equal parent_worker_id, report['child_worker_id'],
                   'child SSE worker thread must be a different object than the parent (threads do not survive fork)'

      # Parent's own worker should still be alive and connected — the fork
      # hook only tore down briefly across the syscall.
      assert %i[connected initializing].include?(client.connection_state),
             "parent connection_state unexpected after fork: #{client.connection_state}"
    ensure
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  private

  # Build a Client wired to a local WEBrick SSE server. We bypass the
  # synchronous HTTP fetch by stubbing on_init_failure: :return — the fork
  # tests care about the SSE thread lifecycle, not the initial GET.
  def build_client_for_fork_tests(port: 4691)
    Quonfig::Client.new(
      Quonfig::Options.new(
        sdk_key: '1-fork-test-key',
        api_urls: ["http://127.0.0.1:#{port}/never-listens"],
        enable_sse: true,
        enable_polling: false,
        initialization_timeout_sec: 1,
        on_init_failure: :return,
        context_upload_mode: :none
      ).tap do |opts|
        # Point SSE at the WEBrick server. Options builds sse_api_urls by
        # prepending `stream.` to the api_url host, which would resolve to
        # `stream.127.0.0.1` (not what we want for tests). Override directly.
        opts.instance_variable_set(:@sse_api_urls, ["http://127.0.0.1:#{port}"])
      end
    )
  end
end
