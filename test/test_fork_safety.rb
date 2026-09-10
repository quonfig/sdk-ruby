# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'timeout'

# qfg-lv4n.1 / qfg-ryov: fork safety.
#
# The model (Reforge's, restored in 1.4.0): **the parent process is never
# touched by a fork.** `Process._fork` fans out to the child only; the child
# drops every inherited reference (without closing, stopping, or joining it)
# and rebuilds a fresh set of threads, aggregators, and state.
#
# The incident this file guards against: a long-lived Sidekiq parent forked a
# worker (via the `parallel` gem) and the SDK tore the PARENT's SSE stream
# down before the syscall. The parent kept evaluating stale config for 13 days
# while `connection_state` cheerfully answered `:connected`.
class TestForkSafety < Minitest::Test
  SAMPLE_PAYLOAD = '{"configs":[],"meta":{"version":"v1","environment":"test"}}'
  CONFIG_KEY = 'fork.value'

  PORT_LIFECYCLE     = 4691
  PORT_CHILD_RESTART = 4692
  PORT_STOPPED       = 4693
  PORT_E2E           = 4694
  PORT_PARENT_LIVE   = 4695
  PORT_PARENT_SAME   = 4696
  PORT_CHILD_UPDATE  = 4697
  PORT_CHILD_AGGS    = 4698
  PORT_HONEST_STATE  = 4699
  PORT_ATEXIT        = 4700
  PORT_HOOK_RESCUE   = 4701
  PORT_DATADIR_TEL   = 4702
  PORT_UNUSED_CHILD  = 4703
  PORT_GUARD         = 4704
  PORT_CONCURRENT    = 4705
  PORT_REARM         = 4706
  PORT_STOP_RACE     = 4707
  PORT_PARENT_CALL   = 4708
  PORT_DATADIR_SSE   = 4709
  PORT_READERS       = 4710
  PORT_RAISE         = 4711
  PORT_RAISE_SSE     = 4712
  PORT_ON_UPDATE     = 4713
  PORT_ORPHAN        = 4714

  # rack-timeout's RequestTimeoutException and Ruby 3.3's
  # Timeout::ExitException are both Exception (not StandardError) subclasses,
  # so they cross a `rescue StandardError` untouched. This is the shape that
  # left a child dark forever when it fired mid-rebuild.
  class RackTimeoutLike < Exception; end # rubocop:disable Lint/InheritException

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

  # SSE endpoint that HOLDS THE STREAM OPEN, exactly like api-delivery-sse.
  # On connect it writes the current payload; after that the test pushes new
  # payloads on demand and every live stream receives them. This is what lets
  # us assert "the parent is still receiving updates after a fork" — the
  # OneShotEndpoint above closes the stream immediately, so it can only ever
  # prove that *someone* dialed, never that a specific process is still live.
  class StreamEndpoint < WEBrick::HTTPServlet::AbstractServlet
    CLOSE = :__close__

    @mutex = Mutex.new
    @queues = []
    @hits = 0
    @event_id = 0
    @current = nil

    class << self
      def reset!(initial_payload)
        @mutex.synchronize do
          @queues = []
          @hits = 0
          @event_id = 0
          @current = initial_payload
        end
      end

      def hits
        @mutex.synchronize { @hits }
      end

      def live_streams
        @mutex.synchronize { @queues.size }
      end

      # Broadcast to every live stream AND make this the payload a
      # freshly-connecting client is handed on connect.
      def push(payload)
        queues = @mutex.synchronize do
          @current = payload
          @queues.dup
        end
        queues.each { |q| q << payload }
        queues.size
      end

      def close_all!
        queues = @mutex.synchronize { @queues.dup }
        queues.each { |q| q << CLOSE }
      end

      def open_stream
        @mutex.synchronize do
          @hits += 1
          queue = Queue.new
          @queues << queue
          [queue, @current]
        end
      end

      def close_stream(queue)
        @mutex.synchronize { @queues.delete(queue) }
      end

      # The payload a freshly-connecting client (SSE *or* HTTP) is handed.
      def current
        @mutex.synchronize { @current }
      end

      def frame(payload)
        id = @mutex.synchronize { @event_id += 1 }
        "id: #{id}\ndata: #{payload}\n\n"
      end
    end

    def do_GET(_request, response)
      queue, current = self.class.open_stream
      response.status = 200
      response['Content-Type'] = 'text/event-stream'
      response['Cache-Control'] = 'no-cache'
      response.chunked = true
      response.body = lambda do |out|
        out.write(self.class.frame(current)) if current
        loop do
          payload = queue.pop
          break if payload == CLOSE

          out.write(self.class.frame(payload))
        end
      rescue StandardError
        nil # client hung up; nothing to do
      ensure
        self.class.close_stream(queue)
      end
    end
  end

  # The HTTP config endpoint (`GET /api/v2/configs`) the SDK fetches on
  # initialization — including the initialization a forked child performs on
  # its FIRST use of the client. Serves whatever envelope StreamEndpoint is
  # currently handing out, and counts requests so a test can prove a child
  # that never touched the client asked the server for nothing.
  class ConfigsEndpoint < WEBrick::HTTPServlet::AbstractServlet
    @mutex = Mutex.new
    @hits = 0
    @mode = :ok
    @delay_s = 0

    class << self
      def reset!
        @mutex.synchronize do
          @hits = 0
          @mode = :ok
          @delay_s = 0
        end
      end

      def hits
        @mutex.synchronize { @hits }
      end

      # :ok serves the current envelope; :fail answers 500 (so the child's
      # own fetch fails the way a real outage does). +delay_s+ holds the
      # response open, which is what makes "a second caller arrives while the
      # first is still fetching" deterministic.
      def mode!(mode, delay_s: 0)
        @mutex.synchronize do
          @mode = mode
          @delay_s = delay_s
        end
      end

      def hit!
        @mutex.synchronize { [@hits += 1, @mode, @delay_s] }
      end
    end

    def do_GET(_request, response)
      _, mode, delay = self.class.hit!
      sleep delay if delay.positive?
      if mode == :fail
        response.status = 500
        response.body = 'nope'
        return
      end
      response.status = 200
      response['Content-Type'] = 'application/json'
      response.body = TestForkSafety::StreamEndpoint.current.to_s
    end
  end

  # Records every telemetry POST that reaches the TEST process. A forked
  # child that re-POSTs the parent's window is only visible here — an
  # in-process transport stub cannot see it, because fork gives the child its
  # own copy of the stub.
  class TelemetrySink < WEBrick::HTTPServlet::AbstractServlet
    @mutex = Mutex.new
    @posts = []

    class << self
      def reset!
        @mutex.synchronize { @posts = [] }
      end

      def posts
        @mutex.synchronize { @posts.dup }
      end

      def record(body)
        @mutex.synchronize { @posts << body }
      end
    end

    def do_POST(request, response)
      body =
        begin
          JSON.parse(request.body)
        rescue StandardError
          { 'raw' => request.body }
        end
      self.class.record(body)
      response.status = 200
      response['Content-Type'] = 'application/json'
      response.body = '{}'
    end
  end

  def setup
    super
    OneShotEndpoint.event_id = 0
    OneShotEndpoint.hits = 0
    StreamEndpoint.reset!(envelope_payload('v0', generation: 1))
    TelemetrySink.reset!
    ConfigsEndpoint.reset!
  end

  def start_webrick_server(port, endpoint_class, telemetry: false, configs: false)
    log_string = StringIO.new
    logger = WEBrick::Log.new(log_string)
    server = WEBrick::HTTPServer.new(Port: port, Logger: logger, AccessLog: [])
    server.mount '/api/v2/sse', endpoint_class
    server.mount '/api/v1/telemetry', TelemetrySink if telemetry
    server.mount '/api/v2/configs', ConfigsEndpoint if configs
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

  # before_fork_in_parent is DEPRECATED as of 1.4.0 (the fork hook no longer
  # calls it) but stays public for semver, and must still do what it says:
  # close the SSE worker and drop the reference. Idempotent.
  def test_before_fork_in_parent_closes_sse_worker
    server, = start_webrick_server(PORT_LIFECYCLE, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: PORT_LIFECYCLE)
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
    server, = start_webrick_server(PORT_CHILD_RESTART, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: PORT_CHILD_RESTART)
    begin
      wait_for -> { client.connection_state == :connected }, max_wait: 5
      original_sse = client.instance_variable_get(:@sse_client)
      original_worker = original_sse.instance_variable_get(:@worker)

      # Simulate the child side of the fork lifecycle in a single process.
      # (before_fork_in_parent is called explicitly here only so the
      # single-process simulation doesn't leave the parent's real worker
      # running against the same WEBrick server; the hook itself no longer
      # calls it.)
      client.before_fork_in_parent
      simulate_fork_child_pid!(client)
      client.after_fork_in_child

      assert_nil client.instance_variable_get(:@sse_client),
                 'the hook itself must not start anything — re-initialization is lazy, on first use'

      # First use of the client is what re-initializes it.
      client.get(CONFIG_KEY, nil)

      new_sse = client.instance_variable_get(:@sse_client)
      new_worker = new_sse&.instance_variable_get(:@worker)

      refute_nil new_sse, 'the first use after a fork must reconstruct the SSE client'
      refute_same original_sse, new_sse,
                  'after_fork_in_child must allocate a fresh SSE client (not reuse the parent object)'
      refute_same original_worker, new_worker,
                  'after_fork_in_child must allocate a fresh worker thread'
      assert new_worker.alive?, 'fresh SSE worker thread must be alive'

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

  # The child logs exactly one info line saying it rebuilt, so a customer
  # grepping their logs can see the SDK noticed the fork.
  def test_after_fork_in_child_logs_one_info_line
    server, = start_webrick_server(PORT_E2E, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: PORT_E2E)
    original_level = Quonfig::Client::LOG.level
    begin
      wait_for -> { client.connection_state == :connected }, max_wait: 5

      Quonfig::Client::LOG.level = :info
      client.before_fork_in_parent
      simulate_fork_child_pid!(client)
      client.after_fork_in_child
      # The line is logged when the client re-initializes — i.e. on first use,
      # not inside the hook.
      client.get(CONFIG_KEY, nil)

      assert_logged([
                      /Initialization did not complete cleanly/,
                      /re-initialized after fork pid=#{Process.pid} components=sse/
                    ])
    ensure
      Quonfig::Client::LOG.level = original_level
      client.stop
      server.stop
    end
  end

  # If the customer explicitly stopped the client, after_fork_in_child must
  # NOT resurrect threads — that would silently undo `stop` after a fork.
  def test_after_fork_in_child_is_a_noop_when_stopped
    server, = start_webrick_server(PORT_STOPPED, OneShotEndpoint)
    Thread.new { server.start }

    client = build_client_for_fork_tests(port: PORT_STOPPED)
    client.stop

    client.after_fork_in_child

    assert_nil client.instance_variable_get(:@sse_client),
               'after_fork_in_child must not start SSE on a stopped client'

    # ...and using a stopped client in the child must not resurrect it either:
    # lazy re-initialization must respect `stop`.
    client.get(CONFIG_KEY, nil)

    assert_nil client.instance_variable_get(:@sse_client),
               'a stopped client must stay stopped across a fork, even when used'
    assert_equal :disconnected, client.connection_state
  ensure
    server.stop
    assert_logged([/Initialization did not complete cleanly/])
  end

  # The Process._fork hook (Ruby 3.1+) must be installed at load time on
  # Process.singleton_class so any Process.fork / Kernel#fork goes through
  # our child-side lifecycle without customer wiring.
  def test_process_fork_hook_is_installed_on_supported_rubies
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    assert defined?(Quonfig::ForkSafety),
           'Quonfig::ForkSafety must be defined so Process._fork can be overridden'
    assert Process.singleton_class.include?(Quonfig::ForkSafety),
           'Quonfig::ForkSafety must be prepended into Process.singleton_class to override _fork'
  end

  # ------------------------------------------------------------------
  # T1 — the assertion that would have caught the Cheddar Up incident.
  #
  # The parent keeps receiving live updates after a fork. Nothing about the
  # parent may change across somebody else's fork(2).
  # ------------------------------------------------------------------
  def test_parent_keeps_receiving_sse_updates_after_a_fork
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_PARENT_LIVE, StreamEndpoint)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(port: PORT_PARENT_LIVE)

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial SSE envelope'

      pid = Process.fork { exit!(0) }
      Process.waitpid(pid)

      # Publish AFTER the fork. A parent that was torn down by the fork hook
      # will never see this.
      StreamEndpoint.push(envelope_payload('v1', generation: 2))

      assert wait_until(6) { client.get(CONFIG_KEY, nil) == 'v1' },
             "parent stopped receiving SSE updates after a fork (value=#{client.get(CONFIG_KEY, nil).inspect}, " \
             "connection_state=#{client.connection_state})"

      sse = client.instance_variable_get(:@sse_client)
      refute_nil sse, 'the fork must not drop the parent SSE client'
      assert sse.instance_variable_get(:@worker)&.alive?,
             'the parent SSE worker thread must still be alive after a fork'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # ------------------------------------------------------------------
  # T2 — object identity. The parent's SSE client and worker Thread must be
  # the SAME objects before and after somebody forks. This is the guard
  # against re-introducing any parent-side teardown/restart cycle (a restart
  # would also "work" for T1, but it drops the stream and re-dials, which is
  # exactly the churn we are removing).
  # ------------------------------------------------------------------
  def test_fork_does_not_touch_the_parents_threaded_components
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_PARENT_SAME, StreamEndpoint)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(port: PORT_PARENT_SAME)

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial SSE envelope'

      sse_before = client.instance_variable_get(:@sse_client)
      worker_before = sse_before.instance_variable_get(:@worker)
      loader_before = client.instance_variable_get(:@config_loader)
      refute_nil worker_before

      pid = Process.fork { exit!(0) }
      Process.waitpid(pid)

      assert_same sse_before, client.instance_variable_get(:@sse_client),
                  'the fork hook must not replace the PARENT SSE client'
      assert_same worker_before,
                  client.instance_variable_get(:@sse_client).instance_variable_get(:@worker),
                  'the fork hook must not replace the PARENT SSE worker thread'
      assert_same loader_before, client.instance_variable_get(:@config_loader),
                  'the fork hook must not replace the PARENT config loader'
      assert worker_before.alive?,
             'the fork hook must not kill the PARENT SSE worker thread'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # ------------------------------------------------------------------
  # T3 — the child re-initializes on its FIRST use of the client, exactly
  # like a newly constructed client: empty store, its own config fetch, its
  # own threads. It never evaluates from the snapshot the parent happened to
  # hold at fork time. (Jeff, 2026-09-10: full Reforge parity — fresh store,
  # lazy rebuild.)
  #
  # The config published AFTER the fork and BEFORE the child's first call is
  # what the child's very first `get` must return. That is only possible if
  # the child fetched it itself.
  #
  # (T6: this replaces the old end-to-end test, whose parent-side assertion
  # read `connection_state` — the diagnostic that lied.)
  # ------------------------------------------------------------------
  def test_child_first_use_fetches_its_own_current_config
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_CHILD_UPDATE, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_CHILD_UPDATE,
      api_urls: ["http://127.0.0.1:#{PORT_CHILD_UPDATE}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'

      parent_sse_id = client.instance_variable_get(:@sse_client).object_id
      parent_worker_id = client.instance_variable_get(:@sse_client)
                               .instance_variable_get(:@worker).object_id
      config_hits_before = ConfigsEndpoint.hits

      report = fork_and_capture(
        gate: true,
        after_fork: -> { StreamEndpoint.push(envelope_payload('v1', generation: 2)) }
      ) do
        # Peek at the raw store WITHOUT going through a read entry point —
        # every one of those triggers the re-initialization.
        keys_before = client.instance_variable_get(:@store).keys.size
        state_before = client.connection_state.to_s

        first_value = client.get(CONFIG_KEY, nil)

        sse = client.instance_variable_get(:@sse_client)
        {
          'keys_before_first_use' => keys_before,
          'state_before_first_use' => state_before,
          'first_value' => first_value,
          'state_after_first_use' => client.connection_state.to_s,
          'ready_after_first_use' => client.ready?,
          'sse_id' => sse&.object_id,
          'worker_id' => sse&.instance_variable_get(:@worker)&.object_id,
          'worker_alive' => sse&.instance_variable_get(:@worker)&.alive? || false
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 0, report['keys_before_first_use'],
                   'the child must NOT inherit the parent config snapshot — its store starts empty'
      refute_equal 'connected', report['state_before_first_use'],
                   'a child that has not used the client yet must not claim to be connected ' \
                   "(got #{report['state_before_first_use']})"
      assert_equal 'v1', report['first_value'],
                   "the child's FIRST get must block on its own fetch and return the CURRENT " \
                   "server config, not the parent's snapshot (got #{report['first_value'].inspect})"
      assert_equal 'connected', report['state_after_first_use']
      assert report['ready_after_first_use']
      refute_equal parent_sse_id, report['sse_id'],
                   'child must build a fresh SSE client, not reuse the inherited one'
      refute_equal parent_worker_id, report['worker_id'],
                   'child SSE worker thread must be a different object than the parent (threads do not survive fork)'
      assert report['worker_alive'], 'child SSE worker thread must be alive'

      assert_operator ConfigsEndpoint.hits, :>, config_hits_before,
                      "the child's first use must fetch its own config"

      # T1 again, from the other side: the parent that forked is still live.
      assert wait_until(6) { client.get(CONFIG_KEY, nil) == 'v1' },
             'parent stopped receiving SSE updates after forking a child'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # The other half of lazy: a child that never touches the client costs
  # nothing. No fetch, no stream, no thread — and `stop` returns promptly
  # without going near the network.
  # ------------------------------------------------------------------
  def test_child_that_never_uses_the_client_costs_nothing
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_UNUSED_CHILD, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_UNUSED_CHILD,
      api_urls: ["http://127.0.0.1:#{PORT_UNUSED_CHILD}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'

      # The parent's own stream has to be up before we snapshot the counters,
      # otherwise its dial lands mid-test and looks like the child's.
      assert wait_until(5) { StreamEndpoint.live_streams >= 1 },
             'parent never opened its SSE stream'

      config_hits_before = ConfigsEndpoint.hits
      sse_hits_before = StreamEndpoint.hits

      # (a) a child that does nothing at all, exiting the normal way.
      pid = fork_with_normal_exit
      _, status = Process.waitpid2(pid)

      assert_predicate status, :success?, "an unused forked child must exit 0 (got #{status.inspect})"

      # (b) a child whose only interaction is `stop`.
      report = fork_and_capture do
        # Sampled BEFORE `stop` — and before anything else touches the
        # client. The server-side counters below cannot see a worker that was
        # started but has not dialed yet, and a child that exits fast beats
        # its own SSE worker to the socket, which is exactly why they passed
        # against an eager post-fork rebuild. Counting threads inside the
        # child is what pins "nothing was started": a fresh child has exactly
        # one thread, its main one.
        threads = Thread.list.size
        thread_names = Thread.list.map { |t| t.name || t.inspect }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        client.stop
        { 'stop_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
          'sse_nil' => client.instance_variable_get(:@sse_client).nil?,
          'threads' => threads,
          'thread_names' => thread_names }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_operator report['stop_seconds'], :<, 2.0,
                      "stop in an unused child must return promptly (took #{report['stop_seconds']}s)"
      assert report['sse_nil'], 'stop must not have started anything in an unused child'
      assert_equal 1, report['threads'],
                   'a child that never used the client must run NO SDK threads ' \
                   "(saw #{report['thread_names'].inspect})"

      # Neither child may have asked the server for a thing.
      assert_equal config_hits_before, ConfigsEndpoint.hits,
                   'a child that never used the client must not fetch config'
      assert_equal sse_hits_before, StreamEndpoint.hits,
                   'a child that never used the client must not open an SSE stream'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # The child's fresh store starts at generation zero, so the first envelope
  # it fetches is ACCEPTED. (Inheriting the parent's loader watermark meant
  # the child's own first fetch was dropped by the reject-older guard as
  # "same generation" — visible as guardRejected in its telemetry window.)
  #
  # SSE is off here so the only install is the first fetch: the assertion is
  # deterministic rather than racing the stream's snapshot.
  # ------------------------------------------------------------------
  def test_child_first_fetch_is_not_guard_rejected
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_GUARD, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_GUARD,
      api_urls: ["http://127.0.0.1:#{PORT_GUARD}"],
      enable_sse: false
    )

    begin
      assert_equal 'v0', client.get(CONFIG_KEY, nil), 'parent never installed the initial envelope'
      assert_equal 1, client.config_install_count

      report = fork_and_capture(gate: true, after_fork: -> { StreamEndpoint.push(envelope_payload('v1', generation: 2)) }) do
        value = client.get(CONFIG_KEY, nil)
        failover_event = client.instance_variable_get(:@failover_aggregator).drain_event
        {
          'value' => value,
          'install_count' => client.config_install_count,
          'held_generation' => client.held_generation,
          'guard_rejected' => failover_event ? failover_event['failover']['guardRejected'] : 0
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'v1', report['value']
      assert_equal 1, report['install_count'],
                   "the child's own first fetch must be INSTALLED, not dropped by the reject-older guard"
      assert_equal 2, report['held_generation']
      assert_equal 0, report['guard_rejected'],
                   'a child starting from an empty store must record no guard rejection on its first fetch'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # T4 — the child's telemetry aggregators and failover aggregator are FRESH,
  # EMPTY objects. A child that inherits and later flushes the parent's
  # aggregators double-reports the parent's data.
  # ------------------------------------------------------------------
  def test_child_gets_fresh_empty_aggregators
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_CHILD_AGGS, StreamEndpoint)
    server_thread = Thread.new { server.start }
    client = build_telemetry_client_for_fork_tests(port: PORT_CHILD_AGGS)
    stub_telemetry_transport(client)

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial SSE envelope'

      reporter = client.telemetry_reporter
      refute_nil reporter, 'this test needs a live telemetry reporter in the parent'

      # Dirty the parent's aggregators so "the child's are empty" is a real
      # assertion and not vacuously true.
      parent_failover = client.instance_variable_get(:@failover_aggregator)
      parent_failover.record_hedge_fired
      client.get(CONFIG_KEY, nil)

      ids = {
        'failover' => parent_failover.object_id,
        'reporter' => reporter.object_id,
        'summaries' => reporter.instance_variable_get(:@evaluation_summaries_aggregator).object_id,
        'shapes' => reporter.instance_variable_get(:@context_shape_aggregator).object_id
      }

      report = fork_and_capture do
        child_reporter = client.telemetry_reporter
        child_failover = client.instance_variable_get(:@failover_aggregator)
        loader_failover = client.instance_variable_get(:@config_loader)
                                .instance_variable_get(:@failover_aggregator)
        {
          'failover_id' => child_failover&.object_id,
          'reporter_id' => child_reporter&.object_id,
          'summaries_id' => child_reporter&.instance_variable_get(:@evaluation_summaries_aggregator)&.object_id,
          'shapes_id' => child_reporter&.instance_variable_get(:@context_shape_aggregator)&.object_id,
          'failover_pending' => !child_failover&.drain_event.nil?,
          'summaries_pending' => !child_reporter&.instance_variable_get(:@evaluation_summaries_aggregator)
                                  &.drain_event.nil?,
          'loader_uses_child_failover' => loader_failover&.object_id == child_failover&.object_id
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      refute_equal ids['failover'], report['failover_id'],
                   'child must get a FRESH failover aggregator, not the parent object'
      refute_equal ids['reporter'], report['reporter_id'],
                   'child must get a FRESH telemetry reporter, not the parent object'
      refute_equal ids['summaries'], report['summaries_id'],
                   'child must get a FRESH evaluation-summaries aggregator'
      refute_equal ids['shapes'], report['shapes_id'],
                   'child must get a FRESH context-shape aggregator'
      refute report['failover_pending'],
             'child failover aggregator must start empty (it must not inherit the parent counters)'
      refute report['summaries_pending'],
             'child evaluation-summaries aggregator must start empty'
      assert report['loader_uses_child_failover'],
             "the child's config loader must record into the child's failover aggregator, not the parent's"
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # ------------------------------------------------------------------
  # The fan-out is per-instance: one client blowing up in
  # `after_fork_in_child` must not cost every client behind it in the
  # registry its rebuild. A process with two clients (say, one for flags and
  # one for a second workspace) would otherwise lose the second one to any
  # transient failure in the first — thread exhaustion, a customer logger
  # that raises — and the only symptom is a silently dark child.
  # ------------------------------------------------------------------
  def test_one_client_raising_does_not_skip_the_rest_of_the_registry
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_HOOK_RESCUE, StreamEndpoint)
    server_thread = Thread.new { server.start }
    first = build_client_for_fork_tests(port: PORT_HOOK_RESCUE)
    second = build_client_for_fork_tests(port: PORT_HOOK_RESCUE)
    raiser = nil

    begin
      assert wait_until(5) { first.get(CONFIG_KEY, nil) == 'v0' && second.get(CONFIG_KEY, nil) == 'v0' },
             'both clients must be live before the fork'

      # The hook fans out in registry order, so the failure has to land on
      # whichever of the two comes FIRST — otherwise the test proves nothing.
      registered = []
      Quonfig::Client.each_instance { |c| registered << c if c.equal?(first) || c.equal?(second) }

      assert_equal 2, registered.size, 'expected both clients in the fork registry'
      raiser = registered.first
      survivor = registered.last

      raiser.define_singleton_method(:after_fork_in_child) do
        raise 'boom from a customer logger or thread exhaustion'
      end

      report = fork_and_capture do
        # First use re-initializes the client (lazy since 1.4.0); the point of
        # the test is that the surviving client is still usable at all.
        survivor.get(CONFIG_KEY, nil)
        connected = wait_until(5) { survivor.connection_state == :connected }
        sse = survivor.instance_variable_get(:@sse_client)
        {
          'worker_alive' => sse&.instance_variable_get(:@worker)&.alive? || false,
          'connected' => connected,
          'state' => survivor.connection_state.to_s,
          'logged_continuation' => $logs.string.include?('continuing with the rest')
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert report['worker_alive'],
             'a client raising in after_fork_in_child skipped every client behind it in the registry ' \
             "(surviving client: worker_alive=#{report['worker_alive']}, state=#{report['state']})"
      assert report['connected'],
             "the surviving client never reached :connected in the child (state=#{report['state']})"
      assert report['logged_continuation'],
             'the per-instance failure must be logged as such, not swallowed by the hook-wide rescue'
    ensure
      raiser&.singleton_class&.send(:remove_method, :after_fork_in_child)
      StreamEndpoint.close_all!
      first.stop
      second.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # ------------------------------------------------------------------
  # T4b — a child that exits NORMALLY must not re-POST the PARENT's
  # telemetry window.
  #
  # `TelemetryReporter#start` registers a process-wide
  # `Kernel.at_exit { final_drain_on_exit }` closure over the reporter.
  # fork(2) copies it. Dropping `@telemetry_reporter` in the child does not
  # unregister it — the closure still holds the inherited reporter, whose
  # aggregators are a full copy of the parent's un-flushed window. Any child
  # that exits the normal way (block-form `fork` + `exit`, which is what the
  # `parallel` gem does) therefore POSTs the parent's data under the parent's
  # instanceHash, and the parent POSTs it again from its own copy.
  # ------------------------------------------------------------------
  def test_child_normal_exit_does_not_reflush_the_parents_telemetry
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_ATEXIT, StreamEndpoint, telemetry: true)
    server_thread = Thread.new { server.start }
    client = build_telemetry_client_for_fork_tests(
      port: PORT_ATEXIT,
      telemetry_url: "http://127.0.0.1:#{PORT_ATEXIT}"
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial SSE envelope'
      refute_nil client.telemetry_reporter, 'this test needs a live telemetry reporter in the parent'

      # Dirty the parent's window. None of this belongs to any child.
      100.times { client.get(CONFIG_KEY, nil, { 'user' => { 'key' => 'u1' } }) }

      # A child that evaluates NOTHING and exits normally.
      pid = fork_with_normal_exit
      Process.waitpid(pid)
      wait_until(3) { !TelemetrySink.posts.empty? } # give a child POST time to land

      child_posts = TelemetrySink.posts

      assert_empty child_posts,
                   'a normally-exiting child re-POSTed the parent telemetry window ' \
                   "(#{child_posts.size} POST(s), " \
                   "evaluations=#{child_posts.sum { |p| telemetry_evaluations_in(p) }}, " \
                   "instanceHash matches parent=#{child_posts.all? { |p| p['instanceHash'] == client.instance_hash }})"

      # ...and the parent's own flush still arrives, exactly once, with the
      # full window. The guard must silence the CHILD, not the owner.
      client.stop

      assert wait_until(5) { TelemetrySink.posts.size == 1 },
             "expected exactly one telemetry POST from the parent, got #{TelemetrySink.posts.size}"
      parent_post = TelemetrySink.posts.first

      assert_equal client.instance_hash, parent_post['instanceHash']
      assert_operator telemetry_evaluations_in(parent_post), :>=, 100,
                      "the parent's own flush lost evaluations: #{telemetry_evaluations_in(parent_post)}"
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # ------------------------------------------------------------------
  # qfg-vquv — a forked DATADIR child must get its own telemetry reporter.
  #
  # The datadir branch of `after_fork_in_child` returned before the
  # aggregator/reporter rebuild, so a datadir + SDK-key child (a supported,
  # emitting combination since 1.3.0 / qfg-5x9x) recorded nothing of its own
  # for the rest of its life — and, before the owner-pid guard, re-POSTed the
  # PARENT's window at exit instead.
  # ------------------------------------------------------------------
  def test_datadir_child_gets_a_fresh_telemetry_reporter
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    workspace = build_datadir_workspace('d0')
    client = Quonfig::Client.new(
      sdk_key: 'qf_sk_dev_abc_deadbeef',
      datadir: workspace,
      environment: 'test',
      telemetry_url: "http://127.0.0.1:#{PORT_DATADIR_TEL}/never-listens",
      enable_sse: false,
      fallback_poll_enabled: false,
      # Long enough that the background loop never fires during the test.
      collect_sync_interval: 3600
    )

    begin
      assert_equal 'd0', client.get(CONFIG_KEY, nil)

      parent_reporter = client.telemetry_reporter

      refute_nil parent_reporter,
                 'datadir + SDK key must have a telemetry reporter in the parent (qfg-5x9x)'

      # Dirty the parent's window so "the child's is empty" is a real assertion.
      50.times { client.get(CONFIG_KEY, nil, { 'user' => { 'key' => 'p' } }) }

      parent_ids = {
        'reporter' => parent_reporter.object_id,
        'summaries' => parent_reporter.instance_variable_get(:@evaluation_summaries_aggregator).object_id,
        'failover' => client.instance_variable_get(:@failover_aggregator).object_id
      }

      report = fork_and_capture(
        gate: true,
        # Rewrite the workspace on disk after the fork: the child must load
        # the CURRENT contents itself, not inherit the parent's snapshot.
        after_fork: -> { write_datadir_value(workspace, 'd1') }
      ) do
        # First use re-initializes: load the datadir, start the watcher, start
        # this child's own telemetry reporter.
        first_value = client.get(CONFIG_KEY, nil, { 'user' => { 'key' => 'c' } })
        child_reporter = client.telemetry_reporter
        child_failover = client.instance_variable_get(:@failover_aggregator)
        summaries = child_reporter&.instance_variable_get(:@evaluation_summaries_aggregator)
        {
          'first_value' => first_value,
          'reporter_nil' => child_reporter.nil?,
          'reporter_id' => child_reporter&.object_id,
          'summaries_id' => summaries&.object_id,
          'failover_id' => child_failover&.object_id,
          'owner_pid_is_child' => child_reporter&.owner_pid == Process.pid,
          'thread_alive' => child_reporter&.instance_variable_get(:@thread)&.alive? || false,
          # Drained AFTER one child evaluation: the child records its own
          # usage and nothing of the parent's.
          'own_evaluations' => telemetry_evaluations_in('events' => [summaries&.drain_event].compact)
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'd1', report['first_value'],
                   'the datadir child must load the workspace itself on first use, ' \
                   "not evaluate from the parent's snapshot"
      refute report['reporter_nil'],
             'a forked datadir child got no telemetry reporter at all (qfg-vquv)'
      refute_equal parent_ids['reporter'], report['reporter_id'],
                   'the datadir child must get a FRESH reporter, not the inherited one'
      refute_equal parent_ids['summaries'], report['summaries_id'],
                   'the datadir child must get a FRESH evaluation-summaries aggregator'
      refute_equal parent_ids['failover'], report['failover_id'],
                   'the datadir child must get a FRESH failover aggregator'
      assert report['owner_pid_is_child'],
             "the child's reporter must own its own pid, so it is the one allowed to flush"
      assert report['thread_alive'], "the child's reporter must actually be running"
      assert_equal 1, report['own_evaluations'],
                   "the child's window must hold exactly its own evaluations, not the parent's 50+"
    ensure
      client.stop
      FileUtils.remove_entry(workspace) if workspace && Dir.exist?(workspace)
    end
  end

  # ------------------------------------------------------------------
  # T5 — connection_state must never answer :connected when nothing is
  # actually alive. It has to derive from liveness, not from a stored flag
  # left behind by a torn-down session. (This is the diagnostic that let the
  # incident hide for 13 days.)
  # ------------------------------------------------------------------
  def test_connection_state_is_not_connected_without_a_live_component
    server, = start_webrick_server(PORT_HONEST_STATE, StreamEndpoint)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(port: PORT_HONEST_STATE)

    begin
      assert wait_until(5) { client.connection_state == :connected },
             'client never reached :connected'

      # The deprecated manual pre-fork teardown leaves nothing alive.
      client.before_fork_in_parent

      assert_nil client.instance_variable_get(:@sse_client)
      refute_equal :connected, client.connection_state,
                   'connection_state reported :connected with no SSE client and no poller alive'
      assert_equal :disconnected, client.connection_state

      client.stop
      assert_equal :disconnected, client.connection_state
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
    end
  end

  # ------------------------------------------------------------------
  # D1 — every thread that reaches the client first in a forked child must
  # BLOCK on the one in-flight rebuild and then see the fetched config.
  #
  # The unlocked fast path (`return unless @fork_rebuild_pending`) combined
  # with clearing the flag BEFORE doing the work meant only the winner of the
  # mutex blocked: every other thread read `false`, skipped the mutex
  # entirely, and evaluated against the brand-new EMPTY store. In a Puma
  # worker (or any threaded child) that is a burst of nils/defaults on the
  # first request after boot.
  #
  # Exactly one fetch and one SSE dial: the waiters must not each start their
  # own rebuild either.
  # ------------------------------------------------------------------
  def test_concurrent_first_use_in_a_child_all_wait_for_the_one_rebuild
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_CONCURRENT, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_CONCURRENT,
      api_urls: ["http://127.0.0.1:#{PORT_CONCURRENT}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'
      assert wait_until(5) { StreamEndpoint.live_streams >= 1 }, 'parent never opened its SSE stream'

      config_hits_before = ConfigsEndpoint.hits
      sse_hits_before = StreamEndpoint.hits
      # Hold the child's fetch open long enough that all 16 threads are
      # inside `get` at the same time.
      ConfigsEndpoint.mode!(:ok, delay_s: 0.4)

      report = fork_and_capture(
        gate: true,
        after_fork: -> { StreamEndpoint.push(envelope_payload('v1', generation: 2)) }
      ) do
        start = Queue.new
        values = Queue.new
        threads = 16.times.map do
          Thread.new do
            start.pop
            values << client.get(CONFIG_KEY, nil)
          end
        end
        16.times { start << true }
        threads.each { |t| t.join(15) }
        collected = 16.times.map { values.empty? ? 'MISSING' : values.pop }
        { 'values' => collected.tally, 'state' => client.connection_state.to_s }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal({ 'v1' => 16 }, report['values'],
                   'every concurrent first-use caller must block on the in-flight rebuild and see ' \
                   "the child's own fetched config (got #{report['values'].inspect})")
      assert_equal 'connected', report['state']
      assert_equal 1, ConfigsEndpoint.hits - config_hits_before,
                   '16 concurrent first-use callers must produce exactly ONE config fetch'
      assert_equal 1, StreamEndpoint.hits - sse_hits_before,
                   '16 concurrent first-use callers must produce exactly ONE SSE dial'
    ensure
      ConfigsEndpoint.mode!(:ok)
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # D2 — a non-StandardError raised mid-rebuild must not leave the child dark
  # forever.
  #
  # rack-timeout's RequestTimeoutException, Ruby 3.3's
  # Timeout::ExitException, and Thread#kill all cross `rescue StandardError`.
  # With the pending flag cleared BEFORE the work, one of those firing during
  # the first `get` in a child meant every later call returned nil against an
  # empty store, with no SSE, no poller and no reporter — permanently.
  # ------------------------------------------------------------------
  def test_non_standard_error_mid_rebuild_leaves_the_child_retryable
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_REARM, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_REARM,
      api_urls: ["http://127.0.0.1:#{PORT_REARM}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'

      config_hits_before = ConfigsEndpoint.hits
      ConfigsEndpoint.mode!(:ok, delay_s: 0.5)

      report = fork_and_capture(
        gate: true,
        after_fork: -> { StreamEndpoint.push(envelope_payload('v1', generation: 2)) }
      ) do
        first =
          begin
            Timeout.timeout(0.15, TestForkSafety::RackTimeoutLike) { client.get(CONFIG_KEY, 'DEFAULT') }
            'no raise'
          rescue TestForkSafety::RackTimeoutLike
            'raised'
          end
        second = client.get(CONFIG_KEY, 'DEFAULT')
        sse = client.instance_variable_get(:@sse_client)
        {
          'first' => first,
          'second' => second,
          'ready' => client.ready?,
          'state' => client.connection_state.to_s,
          'sse_alive' => sse&.alive? || false
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'raised', report['first'],
                   'the probe must actually interrupt the rebuild with a non-StandardError'
      assert_equal 'v1', report['second'],
                   'after a non-StandardError aborted the rebuild the NEXT call must retry it ' \
                   "and return the child's own config (got #{report['second'].inspect})"
      assert report['ready'], 'the retried rebuild must leave the child ready'
      assert_equal 'connected', report['state']
      assert report['sse_alive'], 'the retried rebuild must start the update channel'
      assert_equal 2, ConfigsEndpoint.hits - config_hits_before,
                   'expected the aborted fetch plus exactly one retry'
    ensure
      ConfigsEndpoint.mode!(:ok)
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # D5 — `stop` racing an in-flight post-fork rebuild must not orphan an SSE
  # worker. `stop` cleared the pending flag and tore down without taking the
  # rebuild lock, so a rebuild already past that point went on to build a
  # stream `stop` had no reference to and could never close.
  # ------------------------------------------------------------------
  def test_stop_racing_an_in_flight_rebuild_leaves_no_sse_worker
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_STOP_RACE, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_STOP_RACE,
      api_urls: ["http://127.0.0.1:#{PORT_STOP_RACE}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'

      ConfigsEndpoint.mode!(:ok, delay_s: 0.6)

      report = fork_and_capture do
        rebuilder = Thread.new { client.get(CONFIG_KEY, 'DEFAULT') }
        sleep 0.2 # let the rebuild get into its blocking fetch
        client.stop
        rebuilder.join(10)
        settled = wait_until(5) { sse_worker_thread_count.zero? }
        {
          'sse_worker_threads' => sse_worker_thread_count,
          'settled' => settled,
          'sse_client_nil' => client.instance_variable_get(:@sse_client).nil?,
          'state' => client.connection_state.to_s
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert report['sse_client_nil'],
             'stop during an in-flight rebuild left an SSE client the child can never close'
      assert_equal 0, report['sse_worker_threads'],
                   'stop during an in-flight rebuild orphaned an SSE worker thread'
      assert_equal 'disconnected', report['state']
    ensure
      ConfigsEndpoint.mode!(:ok)
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # D3 — a DATADIR child whose rebuild fails must not dial the network.
  #
  # The failure path started the update channel unconditionally, so a child
  # of a purely offline (datadir) client opened an SSE stream to
  # `stream.primary.quonfig.com` on its first `get`. With no config loader
  # behind it, every envelope that arrived logged "Error applying SSE
  # envelope: undefined method `apply_envelope' for nil" — and because
  # nothing re-armed the rebuild, repairing the file on disk never helped.
  # ------------------------------------------------------------------
  def test_datadir_child_rebuild_failure_does_not_dial_sse
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_DATADIR_SSE, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    workspace = build_datadir_workspace('d0')
    manifest = File.join(workspace, 'quonfig.json')
    good_manifest = File.read(manifest)

    client = Quonfig::Client.new(
      Quonfig::Options.new(
        sdk_key: '1-fork-test-key',
        datadir: workspace,
        environment: 'test',
        api_urls: ["http://127.0.0.1:#{PORT_DATADIR_SSE}"],
        enable_sse: true,
        enable_polling: false,
        # Auto-reload OFF, so the only way a repaired workspace can reach the
        # child is the rebuild being re-armed for the next call.
        data_dir_auto_reload: false,
        # D7 (:raise parity) is exercised on its own below; keep this test
        # about where the failure path DIALS, not about how it reports.
        on_init_failure: :return,
        context_upload_mode: :none,
        collect_evaluation_summaries: false
      ).tap do |opts|
        # Keep any (buggy) dial LOCAL and observable. Without this override a
        # red run reaches out to the real stream.primary host.
        opts.instance_variable_set(:@sse_api_urls, ["http://127.0.0.1:#{PORT_DATADIR_SSE}"])
      end
    )

    begin
      assert_equal 'd0', client.get(CONFIG_KEY, nil)
      sse_hits_before = StreamEndpoint.hits

      report = fork_and_capture(
        gate: true,
        after_fork: lambda {
          write_datadir_value(workspace, 'd1')
          File.write(manifest, '{ not json')
        }
      ) do
        first = client.get(CONFIG_KEY, 'DEFAULT')
        sse_started = !client.instance_variable_get(:@sse_client).nil?
        # Repair the workspace, then use the client again: a re-armed rebuild
        # picks the file back up.
        File.write(manifest, good_manifest)
        second = client.get(CONFIG_KEY, 'DEFAULT')
        {
          'first' => first,
          'sse_started' => sse_started,
          'sse_worker_threads' => sse_worker_thread_count,
          'second' => second,
          'apply_envelope_errors' => $logs.string.scan('Error applying SSE envelope').size
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'DEFAULT', report['first'],
                   'a datadir child whose load failed has nothing to serve but the default'
      refute report['sse_started'],
             'a DATADIR child must never open an SSE stream when its rebuild fails ' \
             '(the client is configured offline; there is no config loader behind the stream)'
      assert_equal 0, report['sse_worker_threads']
      assert_equal 0, report['apply_envelope_errors'],
                   'the child dialed SSE and then failed to apply what arrived'
      assert_equal 'd1', report['second'],
                   'once the workspace is repaired the next call must pick it up'
      assert_equal sse_hits_before, StreamEndpoint.hits,
                   'a datadir child must not dial the SSE server at all'
    ensure
      client.stop
      StreamEndpoint.close_all!
      server.stop
      server_thread&.join(2)
      FileUtils.remove_entry(workspace) if workspace && Dir.exist?(workspace)
    end
  end

  # ------------------------------------------------------------------
  # D4 — `after_fork_in_child` called in the PARENT must be a no-op.
  #
  # The 1.0-1.3 README told customers whose parent keeps evaluating to call
  # `Quonfig.instance.after_fork_in_child` in the parent after `fork`
  # returned; that is the incident customer's documented workaround and it is
  # still out there in production code. On 1.4.0 the parent's components are
  # ALIVE, so each such call orphans a live SSE worker and its stream, zeroes
  # the store, and stops the owner's telemetry reporter.
  # ------------------------------------------------------------------
  def test_after_fork_in_child_called_in_the_parent_is_a_noop
    server, = start_webrick_server(PORT_PARENT_CALL, StreamEndpoint, telemetry: true, configs: true)
    server_thread = Thread.new { server.start }
    client = build_telemetry_client_for_fork_tests(
      port: PORT_PARENT_CALL,
      telemetry_url: "http://127.0.0.1:#{PORT_PARENT_CALL}"
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'
      assert wait_until(5) { StreamEndpoint.live_streams >= 1 }, 'parent never opened its SSE stream'

      reporter = client.telemetry_reporter
      refute_nil reporter, 'this test needs a live telemetry reporter in the parent'
      reporter_thread = reporter.instance_variable_get(:@thread)
      assert reporter_thread&.alive?, 'this test needs a RUNNING telemetry reporter in the parent'

      sse_before = client.instance_variable_get(:@sse_client)
      worker_before = sse_before.instance_variable_get(:@worker)
      sse_hits_before = StreamEndpoint.hits
      config_hits_before = ConfigsEndpoint.hits
      threads_before = sse_worker_thread_count

      # The documented 1.3.0 workaround, three times over.
      3.times { client.after_fork_in_child }

      assert_equal 1, client.instance_variable_get(:@store).keys.size,
                   'a parent-side after_fork_in_child wiped the live store'
      assert_equal 'v0', client.get(CONFIG_KEY, nil)
      assert_same sse_before, client.instance_variable_get(:@sse_client),
                  'a parent-side after_fork_in_child dropped the live SSE client'
      assert worker_before.alive?, 'the live SSE worker must survive a parent-side call'
      assert_same reporter, client.telemetry_reporter
      assert reporter_thread.alive?,
             'a parent-side after_fork_in_child stopped the OWNER telemetry reporter ' \
             '(discard_inherited! must never run in the owning process)'
      assert_equal threads_before, sse_worker_thread_count,
                   'a parent-side after_fork_in_child orphaned SSE worker threads'
      assert_equal sse_hits_before, StreamEndpoint.hits,
                   'a parent-side after_fork_in_child opened extra SSE streams'
      assert_equal config_hits_before, ConfigsEndpoint.hits,
                   'a parent-side after_fork_in_child forced the live parent to re-fetch'

      # The live stream still delivers into the store the parent reads from.
      StreamEndpoint.push(envelope_payload('v1', generation: 2))

      assert wait_until(6) { client.get(CONFIG_KEY, nil) == 'v1' },
             'the parent stopped receiving SSE updates after a parent-side after_fork_in_child'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # D6 — the public `store` / `resolver` / `evaluator` / `config_loader`
  # readers are part of the 1.x surface and bypassed the post-fork
  # chokepoint: in a pending child `client.store.get(k)` answered nil and
  # `client.resolver.get(k, {})` raised MissingDefaultError against the empty
  # store.
  # ------------------------------------------------------------------
  def test_public_component_readers_trigger_the_post_fork_rebuild
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_READERS, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_READERS,
      api_urls: ["http://127.0.0.1:#{PORT_READERS}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'

      %w[store resolver evaluator config_loader].each do |reader|
        report = fork_and_capture do
          value =
            case reader
            when 'store'    then client.store.get(CONFIG_KEY) ? 'present' : 'nil'
            when 'resolver' then client.resolver.get(CONFIG_KEY, {}).to_s
            when 'evaluator' then client.evaluator.class.to_s
            else client.config_loader.held_generation.to_s
            end
          { 'value' => value,
            'pending' => client.instance_variable_get(:@fork_rebuild_pending),
            'store_keys' => client.instance_variable_get(:@store).keys.size }
        end

        refute report['error'], "client.#{reader} in a pending child errored: #{report['error']}"
        refute report['pending'],
               "client.#{reader} must route through the post-fork chokepoint (the rebuild never ran)"
        assert_equal 1, report['store_keys'],
                     "client.#{reader} returned a component reading an EMPTY post-fork store"
      end
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # D7 — `on_init_failure` parity. A fresh Client.new raises under `:raise`;
  # the child's first-use rebuild swallowed the error and returned defaults,
  # so the README's "exactly like a newly constructed client" was false for
  # the one option whose entire job is to decide raise-vs-return. Reforge
  # raises the init error out of `get` itself (config_client.rb#_get waits on
  # the init latch on every call), so raising IS the reference behavior.
  #
  # Subsequent calls keep raising — without re-running the fetch.
  # ------------------------------------------------------------------
  def test_raise_policy_child_raises_out_of_the_first_use_and_does_not_refetch
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_RAISE, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_RAISE,
      api_urls: ["http://127.0.0.1:#{PORT_RAISE}"],
      on_init_failure: :raise,
      # No update channel: the child cannot heal, so "keeps raising" is
      # deterministic rather than a race with the stream.
      enable_sse: false,
      enable_polling: false
    )

    begin
      assert_equal 'v0', client.get(CONFIG_KEY, nil), 'parent never installed the initial envelope'

      config_hits_before = ConfigsEndpoint.hits
      ConfigsEndpoint.mode!(:fail)

      report = fork_and_capture do
        first =
          begin
            "returned #{client.get(CONFIG_KEY, 'DEFAULT').inspect}"
          rescue StandardError => e
            "raised #{e.class}"
          end
        second =
          begin
            "returned #{client.get(CONFIG_KEY, 'DEFAULT').inspect}"
          rescue StandardError => e
            "raised #{e.class}"
          end
        { 'first' => first, 'second' => second }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'raised RuntimeError', report['first'],
                   'under on_init_failure: :raise the first use in a child must raise the init ' \
                   'error, exactly as a freshly constructed client would'
      assert_equal 'raised RuntimeError', report['second'],
                   'under :raise a child that never became ready must keep raising'
      assert_equal 1, ConfigsEndpoint.hits - config_hits_before,
                   'a child that is already known to have failed init must not re-fetch on every call'
    ensure
      ConfigsEndpoint.mode!(:ok)
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      # The "post-fork re-initialization failed" line is logged in the CHILD,
      # so it never reaches this process's $logs.
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ...and the update channel is still started on the way out, so the child
  # heals as soon as the stream delivers an envelope — at which point `get`
  # stops raising. `:return` is unchanged: default returned, one line logged.
  def test_raise_policy_child_still_starts_the_update_channel_and_heals
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_RAISE_SSE, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    raiser = build_client_for_fork_tests(
      port: PORT_RAISE_SSE,
      api_urls: ["http://127.0.0.1:#{PORT_RAISE_SSE}"],
      on_init_failure: :raise
    )
    returner = build_client_for_fork_tests(
      port: PORT_RAISE_SSE,
      api_urls: ["http://127.0.0.1:#{PORT_RAISE_SSE}"],
      on_init_failure: :return
    )

    begin
      assert wait_until(5) { raiser.get(CONFIG_KEY, nil) == 'v0' && returner.get(CONFIG_KEY, nil) == 'v0' },
             'parents never installed the initial envelope'

      ConfigsEndpoint.mode!(:fail)

      report = fork_and_capture do
        first =
          begin
            "returned #{raiser.get(CONFIG_KEY, 'DEFAULT').inspect}"
          rescue StandardError => e
            "raised #{e.class}"
          end
        sse_started = !raiser.instance_variable_get(:@sse_client).nil?
        healed = wait_until(6) do
          raiser.get(CONFIG_KEY, 'DEFAULT') == 'v0'
        rescue StandardError
          false
        end
        # :return is untouched — default back, no raise.
        returned =
          begin
            "returned #{returner.get(CONFIG_KEY, 'DEFAULT').inspect}"
          rescue StandardError => e
            "raised #{e.class}"
          end
        { 'first' => first, 'sse_started' => sse_started, 'healed' => healed, 'return_mode' => returned }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'raised RuntimeError', report['first']
      assert report['sse_started'],
             'the update channel must still be started when the rebuild fails, so the child can heal'
      assert report['healed'],
             'once the stream installed an envelope the child must stop raising and serve config'
      assert_equal 'returned "DEFAULT"', report['return_mode'],
                   'on_init_failure: :return must be unchanged — default returned, nothing raised'
    ensure
      ConfigsEndpoint.mode!(:ok)
      StreamEndpoint.close_all!
      raiser.stop
      returner.stop
      server.stop
      server_thread&.join(2)
      # The "post-fork re-initialization failed" line is logged in the CHILD,
      # so it never reaches this process's $logs.
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # E1 — a child forked from INSIDE an `on_update` callback.
  #
  # `on_update` runs on the SSE worker thread, so a customer who forks from
  # it forks *on* that thread — which makes it the child's one surviving
  # thread. Parent-detection that asks "is the inherited worker Thread
  # alive?" therefore answers YES in a real child: the hook logged "called in
  # a process that still owns live SDK components; ignoring", the child
  # served the parent's snapshot forever, reported `:connected`, and resumed
  # the parent's SSE loop on the shared fd.
  #
  # Parent-detection must be a pid stamp, not thread liveness: a pid mismatch
  # is proof of a fork child whatever the inherited Thread objects claim.
  # ------------------------------------------------------------------
  def test_child_forked_from_inside_on_update_is_not_mistaken_for_the_parent
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_ON_UPDATE, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_ON_UPDATE,
      api_urls: ["http://127.0.0.1:#{PORT_ON_UPDATE}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'
      assert wait_until(5) { StreamEndpoint.live_streams >= 1 }, 'parent never opened its SSE stream'

      parent_sse = client.instance_variable_get(:@sse_client)
      sse_worker = parent_sse.instance_variable_get(:@worker)
      reports = []
      child_dials = nil
      sse_hits_before = nil
      fork_next_update = true

      client.on_update do
        next unless fork_next_update

        fork_next_update = false
        reports << begin
          fork_and_capture(
            hold: 3,
            while_alive: lambda {
              wait_until(2) { StreamEndpoint.hits - sse_hits_before == 1 }
              child_dials = StreamEndpoint.hits - sse_hits_before
            }
          ) do
            {
              'on_sse_worker' => sse_worker.equal?(Thread.current),
              'pending' => client.instance_variable_get(:@fork_rebuild_pending),
              'store_keys' => client.instance_variable_get(:@store).keys.size,
              'state' => client.connection_state.to_s,
              'get' => client.get(CONFIG_KEY, 'DEFAULT'),
              'sse_replaced' => !parent_sse.equal?(client.instance_variable_get(:@sse_client))
            }
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          { 'error' => "#{e.class}: #{e.message}" }
        end
      end

      config_hits_before = ConfigsEndpoint.hits
      sse_hits_before = StreamEndpoint.hits
      StreamEndpoint.push(envelope_payload('v1', generation: 2))

      assert wait_until(10) { !reports.empty? }, 'the on_update callback never forked'
      report = reports.first

      refute report['error'], "child errored: #{report['error']}"
      assert report['on_sse_worker'],
             'this test is only meaningful if on_update really runs on the SSE worker thread'
      assert report['pending'],
             'a child forked from on_update was misclassified as the parent — the fork hook ' \
             'ignored it and it kept serving the parent snapshot'
      assert_equal 0, report['store_keys'],
                   "the child must start from an EMPTY store, not the parent's snapshot"
      assert_equal 'initializing', report['state'],
                   'a child with a pending rebuild must not report :connected'
      assert_equal 'v1', report['get'], "the child's first use must fetch its own config"
      assert report['sse_replaced'], 'the child must dial its OWN stream, not reuse the parent object'
      assert_equal 1, ConfigsEndpoint.hits - config_hits_before,
                   'the child must run exactly one config fetch of its own'
      assert_equal 1, child_dials,
                   'the child must open exactly one SSE stream of its own (sampled while it was ' \
                   'still holding the socket)'

      # ...and the parent is untouched by all of it.
      StreamEndpoint.push(envelope_payload('v2', generation: 3))

      assert wait_until(6) { client.get(CONFIG_KEY, nil) == 'v2' },
             'the parent stopped receiving SSE updates after a fork from inside on_update'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # E2 — a non-StandardError that lands AFTER the update channel is up.
  #
  # `rebuild_in_child!` disarms `@fork_rebuild_pending` after
  # `initialize_network_mode` has already run `start_update_channel`. Anything
  # that escapes in that window (rack-timeout, Timeout::ExitException,
  # Thread#kill) leaves the flag armed *with a live stream*; the retry then
  # re-ran `initialize_network_mode`, dialled a SECOND stream, and overwrote
  # `@sse_client` — orphaning the first worker, which `stop` could no longer
  # close.
  #
  # `start_update_channel` must be idempotent.
  # ------------------------------------------------------------------
  def test_retrying_a_rebuild_that_already_started_the_channel_does_not_orphan_a_stream
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_ORPHAN, StreamEndpoint, configs: true)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(
      port: PORT_ORPHAN,
      api_urls: ["http://127.0.0.1:#{PORT_ORPHAN}"]
    )

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial envelope'
      assert wait_until(5) { StreamEndpoint.live_streams >= 1 }, 'parent never opened its SSE stream'

      config_hits_before = ConfigsEndpoint.hits

      report = fork_and_capture do
        # Prepended IN THE CHILD so the injection can never leak into the rest
        # of this suite. It fires exactly once, immediately after the update
        # channel has spawned its worker.
        Quonfig::Client.prepend(Module.new do
          def start_update_channel
            result = super
            if Thread.current[:quonfig_kill_after_channel]
              Thread.current[:quonfig_kill_after_channel] = false
              raise TestForkSafety::RackTimeoutLike, 'landed after the SSE worker spawned'
            end

            result
          end
        end)

        Thread.current[:quonfig_kill_after_channel] = true
        first =
          begin
            client.get(CONFIG_KEY, 'DEFAULT')
            'no raise'
          rescue TestForkSafety::RackTimeoutLike
            'raised'
          end
        sse1 = client.instance_variable_get(:@sse_client)
        after_first = {
          'pending' => client.instance_variable_get(:@fork_rebuild_pending),
          'sse1_alive' => sse1&.alive? || false
        }

        second = client.get(CONFIG_KEY, 'DEFAULT')
        sleep 0.3
        sse2 = client.instance_variable_get(:@sse_client)
        after_second = {
          'pending' => client.instance_variable_get(:@fork_rebuild_pending),
          'live_sse_clients' => live_sse_client_count,
          'sse_replaced' => !sse1.equal?(sse2),
          'sse1_alive' => sse1&.alive? || false,
          # Zero reconnects on the one surviving client — together with
          # "not replaced" that is exactly one dial for the whole child.
          'sse_restarts' => client.worker_restart_total(layer: '1')
        }

        client.stop
        wait_until(5) { live_sse_client_count.zero? }
        after_stop = { 'live_sse_clients' => live_sse_client_count, 'sse1_alive' => sse1&.alive? || false,
                       'sse_restarts' => after_second['sse_restarts'] }

        { 'first' => first, 'after_first' => after_first, 'second' => second,
          'after_second' => after_second, 'after_stop' => after_stop }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert_equal 'raised', report['first'],
                   'the probe must actually interrupt the rebuild after the channel started'
      assert report['after_first']['pending'],
             'a non-StandardError past the channel must leave the rebuild armed for a retry'
      assert report['after_first']['sse1_alive'],
             'this test is only meaningful if the interrupted rebuild left a LIVE stream behind'
      assert_equal 'v0', report['second'], 'the retry must serve config'
      refute report['after_second']['pending'], 'the retry must complete the rebuild'
      refute report['after_second']['sse_replaced'],
             'the retry replaced a LIVE SSE client — the first one is now an orphan nothing can close'
      assert_equal 1, report['after_second']['live_sse_clients'],
                   'the retry dialled a second stream; exactly one live SSE client is allowed'
      assert_equal 0, report['after_stop']['sse_restarts'],
                   'the one surviving SSE client redialled; the child must open exactly one stream'
      assert_equal 0, report['after_stop']['live_sse_clients'],
                   'stop could not close every stream the child opened (orphaned worker)'
      assert_equal 2, ConfigsEndpoint.hits - config_hits_before,
                   'expected the interrupted fetch plus exactly one retry'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/explicit api_urls disables automatic failover/])
    end
  end

  # ------------------------------------------------------------------
  # E4 — the parent-side no-op must not depend on the parent having threads.
  #
  # `live_components_in_this_process?` asked "is a worker alive / is the
  # reporter mine?". A datadir client with auto-reload off and no SDK key has
  # NO threads and no reporter at all, so the 1.0-1.3 documented workaround
  # (calling `after_fork_in_child` in the parent) sailed straight past the
  # guard: it wiped the live store and re-armed a rebuild in a process that
  # never forked. The pid stamp makes the check exact.
  # ------------------------------------------------------------------
  def test_parent_side_after_fork_in_child_is_a_noop_for_a_threadless_client
    workspace = build_datadir_workspace('d0')

    client = Quonfig::Client.new(
      Quonfig::Options.new(
        datadir: workspace,
        environment: 'test',
        context_upload_mode: :none,
        collect_evaluation_summaries: false,
        data_dir_auto_reload: false
      )
    )

    begin
      assert_equal 'd0', client.get(CONFIG_KEY, nil)
      assert_nil client.instance_variable_get(:@datadir_watcher), 'this test needs a client with NO threads'
      assert_nil client.telemetry_reporter, 'this test needs a client with NO telemetry reporter'

      store_before = client.instance_variable_get(:@store)

      # The documented 1.3.0 workaround, in the process that owns the client.
      3.times { client.after_fork_in_child }

      refute client.instance_variable_get(:@fork_rebuild_pending),
             'a parent-side after_fork_in_child armed a post-fork rebuild in the OWNING process'
      assert_same store_before, client.instance_variable_get(:@store),
                  'a parent-side after_fork_in_child threw away the live store'
      assert_equal 1, client.instance_variable_get(:@store).keys.size
      assert_equal 'd0', client.get(CONFIG_KEY, nil)
    ensure
      client.stop
      FileUtils.rm_rf(workspace)
    end
  end

  private

  # Threads currently executing inside the SSE client. Counting by backtrace
  # rather than by our own reference is the point: an ORPHANED worker is one
  # nothing holds a reference to any more.
  def sse_worker_thread_count
    Thread.list.count { |t| t.backtrace&.any? { |line| line.include?('sse_config_client.rb') } }
  end

  # Every SSE client object still running, whether or not the Client holds a
  # reference to it. An ORPHAN shows up here and nowhere else.
  def live_sse_client_count
    ObjectSpace.each_object(Quonfig::SSEConfigClient).count(&:alive?)
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline

      sleep 0.05
    end
  end

  # Fork a child, run +block+ inside it, and ship the returned Hash back over
  # a pipe as JSON. +after_fork+ (if given) runs in the PARENT immediately
  # after the syscall, before we block on the pipe — that's how a test
  # publishes an envelope the child is waiting for.
  # +gate: true+ holds the child at the very top of +block+ until the parent
  # has run +after_fork+ and released it. That removes the race in "the child's
  # FIRST call must see config published after the fork": without it the child
  # can get there before the parent has published.
  # +hold:+ keeps the child alive (sockets and all) for that many seconds
  # AFTER it has shipped its report, and +while_alive:+ runs in the parent
  # during that window. That is how a test observes server-side state the
  # child is responsible for — a stream it opened, say — without racing the
  # child's exit.
  def fork_and_capture(after_fork: nil, gate: false, hold: 0, while_alive: nil, &block)
    read_io, write_io = IO.pipe
    gate_read, gate_write = gate ? IO.pipe : [nil, nil]

    pid = Process.fork do
      read_io.close
      gate_write&.close
      begin
        gate_read&.read(1) # wait for the parent's go-ahead
        write_io.write(JSON.dump(block.call))
      rescue StandardError => e
        write_io.write(JSON.dump('error' => "#{e.class}: #{e.message}"))
      ensure
        write_io.close
        sleep hold if hold.positive?
        # Exit without running the parent's at_exit (which would re-run Minitest).
        exit!(0)
      end
    end

    write_io.close
    gate_read&.close
    after_fork&.call
    if gate
      gate_write.write('g')
      gate_write.close
    end
    raw = read_io.read
    read_io.close
    while_alive&.call
    Process.waitpid(pid)

    refute_empty raw.to_s, 'child wrote nothing to the pipe — likely crashed before reporting'
    JSON.parse(raw)
  end

  # Fork a child that exits the NORMAL way (`exit`, not `exit!`), so every
  # inherited `at_exit` handler runs — the `parallel` gem / Resque shape, and
  # the only shape that exercises the inherited telemetry drain.
  #
  # Minitest's own autorun `at_exit` is neutralized inside the child first;
  # without that the child would re-run this entire suite.
  def fork_with_normal_exit(&block)
    Process.fork do
      block&.call
      Minitest.class_variable_set(:@@after_run, [])
      Minitest.singleton_class.send(:define_method, :run) { |*| true }
      exit 0
    end
  end

  # A minimal on-disk workspace for datadir-mode fork tests.
  def build_datadir_workspace(value)
    dir = Dir.mktmpdir('quonfig-fork-datadir')
    FileUtils.mkdir_p(File.join(dir, 'configs'))
    File.write(File.join(dir, 'quonfig.json'), JSON.generate({ 'environments' => ['test'] }))
    write_datadir_value(dir, value)
    dir
  end

  def write_datadir_value(dir, value)
    File.write(
      File.join(dir, 'configs', 'fork-value.config.json'),
      JSON.generate(
        'id' => 'fork-c1',
        'key' => CONFIG_KEY,
        'type' => 'config',
        'valueType' => 'string',
        'sendToClientSdk' => false,
        'default' => {
          'rules' => [
            { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
              'value' => { 'type' => 'string', 'value' => value } }
          ]
        }
      )
    )
  end

  # Total evaluations carried by a telemetry POST body.
  def telemetry_evaluations_in(post)
    summaries_event = (post['events'] || []).find { |e| e['summaries'] }
    return 0 unless summaries_event

    summaries_event['summaries']['summaries'].sum do |summary|
      (summary['counters'] || []).sum { |counter| counter['count'].to_i }
    end
  end

  def envelope_payload(value, generation:)
    JSON.generate(
      'configs' => [
        {
          'id' => 'fork-c1',
          'key' => CONFIG_KEY,
          'type' => 'config',
          'valueType' => 'string',
          'sendToClientSdk' => false,
          'default' => {
            'rules' => [
              {
                'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                'value' => { 'type' => 'string', 'value' => value }
              }
            ]
          }
        }
      ],
      'meta' => { 'version' => "v-#{generation}", 'environment' => 'test', 'generation' => generation }
    )
  end

  # Build a Client wired to a local WEBrick SSE server. We bypass the
  # synchronous HTTP fetch by stubbing on_init_failure: :return — the fork
  # tests care about the SSE thread lifecycle, not the initial GET. Telemetry
  # is fully off so the suite never opens a socket to the real telemetry
  # service (see build_telemetry_client_for_fork_tests for the one test that
  # does need a reporter).
  def build_client_for_fork_tests(port: PORT_LIFECYCLE, **overrides)
    Quonfig::Client.new(
      Quonfig::Options.new(
        {
          sdk_key: '1-fork-test-key',
          api_urls: ["http://127.0.0.1:#{port}/never-listens"],
          enable_sse: true,
          enable_polling: false,
          initialization_timeout_sec: 1,
          on_init_failure: :return,
          context_upload_mode: :none,
          collect_evaluation_summaries: false
        }.merge(overrides)
      ).tap do |opts|
        # Point SSE at the WEBrick server. Options builds sse_api_urls by
        # prepending `stream.` to the api_url host, which would resolve to
        # `stream.127.0.0.1` (not what we want for tests). Override directly.
        opts.instance_variable_set(:@sse_api_urls, ["http://127.0.0.1:#{port}"])
      end
    )
  end

  # Same, but with the telemetry collectors ON (pointed at the local WEBrick
  # server) so T4 has real aggregators to compare across the fork.
  def build_telemetry_client_for_fork_tests(port:, telemetry_url: nil)
    build_client_for_fork_tests(
      port: port,
      telemetry_url: telemetry_url || "http://127.0.0.1:#{port}/never-listens",
      context_upload_mode: :periodic_example,
      collect_evaluation_summaries: true,
      # Long enough that the background reporter never fires during the test.
      collect_sync_interval: 600
    )
  end

  # Keep the parent's final drain (Client#stop -> TelemetryReporter#sync) off
  # the wire; we only care about aggregator identity here.
  def stub_telemetry_transport(client)
    fake = Object.new
    def fake.post(_path, _body) = Struct.new(:status).new(200)
    client.telemetry_reporter&.instance_variable_set(:@http_connection, fake)
  end
end
