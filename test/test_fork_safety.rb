# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'json'
require 'tmpdir'
require 'fileutils'

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
  end

  def start_webrick_server(port, endpoint_class, telemetry: false)
    log_string = StringIO.new
    logger = WEBrick::Log.new(log_string)
    server = WEBrick::HTTPServer.new(Port: port, Logger: logger, AccessLog: [])
    server.mount '/api/v2/sse', endpoint_class
    server.mount '/api/v1/telemetry', TelemetrySink if telemetry
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
      client.after_fork_in_child

      assert_logged([
                      /Initialization did not complete cleanly/,
                      /rebuilt after fork in child pid=#{Process.pid} components=sse/
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
  # T3 — the child rebuilds and receives an envelope published AFTER the
  # fork. (T6: this replaces the old end-to-end test, whose parent-side
  # assertion read `connection_state` — the diagnostic that lied.)
  # ------------------------------------------------------------------
  def test_child_receives_an_update_published_after_the_fork
    skip 'Process.fork unavailable on this platform' unless Process.respond_to?(:fork)
    skip "Process._fork requires Ruby 3.1+ (got #{RUBY_VERSION})" unless Process.respond_to?(:_fork)

    server, = start_webrick_server(PORT_CHILD_UPDATE, StreamEndpoint)
    server_thread = Thread.new { server.start }
    client = build_client_for_fork_tests(port: PORT_CHILD_UPDATE)

    begin
      assert wait_until(5) { client.get(CONFIG_KEY, nil) == 'v0' },
             'parent never installed the initial SSE envelope'

      parent_sse_id = client.instance_variable_get(:@sse_client).object_id
      parent_worker_id = client.instance_variable_get(:@sse_client)
                               .instance_variable_get(:@worker).object_id

      report = fork_and_capture(
        after_fork: -> { StreamEndpoint.push(envelope_payload('v1', generation: 2)) }
      ) do
        saw_update = wait_until(10) { client.get(CONFIG_KEY, nil) == 'v1' }
        sse = client.instance_variable_get(:@sse_client)
        {
          'saw_update' => saw_update,
          'value' => client.get(CONFIG_KEY, nil),
          'sse_id' => sse&.object_id,
          'worker_id' => sse&.instance_variable_get(:@worker)&.object_id,
          'worker_alive' => sse&.instance_variable_get(:@worker)&.alive? || false
        }
      end

      refute report['error'], "child errored: #{report['error']}"
      assert report['saw_update'],
             "child did not receive the post-fork SSE update: #{report.inspect}"
      assert_equal 'v1', report['value']
      refute_equal parent_sse_id, report['sse_id'],
                   'child must build a fresh SSE client, not reuse the inherited one'
      refute_equal parent_worker_id, report['worker_id'],
                   'child SSE worker thread must be a different object than the parent (threads do not survive fork)'
      assert report['worker_alive'], 'child SSE worker thread must be alive'

      # T1 again, from the other side: the parent that forked is still live.
      assert wait_until(6) { client.get(CONFIG_KEY, nil) == 'v1' },
             'parent stopped receiving SSE updates after forking a child'
    ensure
      StreamEndpoint.close_all!
      client.stop
      server.stop
      server_thread&.join(2)
      assert_logged([/Initialization did not complete cleanly/])
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

      report = fork_and_capture do
        child_reporter = client.telemetry_reporter
        child_failover = client.instance_variable_get(:@failover_aggregator)
        summaries = child_reporter&.instance_variable_get(:@evaluation_summaries_aggregator)
        client.get(CONFIG_KEY, nil, { 'user' => { 'key' => 'c' } })
        {
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

  private

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
  def fork_and_capture(after_fork: nil, &block)
    read_io, write_io = IO.pipe

    pid = Process.fork do
      read_io.close
      begin
        write_io.write(JSON.dump(block.call))
      rescue StandardError => e
        write_io.write(JSON.dump('error' => "#{e.class}: #{e.message}"))
      ensure
        write_io.close
        # Exit without running the parent's at_exit (which would re-run Minitest).
        exit!(0)
      end
    end

    write_io.close
    after_fork&.call
    raw = read_io.read
    read_io.close
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
    dir
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
