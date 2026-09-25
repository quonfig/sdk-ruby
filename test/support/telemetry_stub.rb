# frozen_string_literal: true

require 'digest'
require 'webrick'

# Fixture pieces for the telemetry transport contract tests
# (integration-test-data/chaos/telemetry-transport-contract.md, qfg-y8je.8).
# Only the endpoint, the clock and the logger are fake; the reporter and its
# retained queue are the real ones.

# A real HTTP server on 127.0.0.1:<ephemeral> that answers each telemetry POST
# from a script: +{ status:, retry_after: }+ or +{ hang: true }+ (hold the
# request until #release or #close). Records the raw body of every POST that
# reaches it, including ones the client later aborts.
class TelemetryStub
  DEFAULT_STEP = { status: 200 }.freeze

  def initialize
    @mutex = Mutex.new
    @cv = ConditionVariable.new
    @bodies = []
    @script = []
    @default = DEFAULT_STEP
    @releases = {}
    @closed = false

    @server = WEBrick::HTTPServer.new(
      BindAddress: '127.0.0.1', Port: 0,
      Logger: WEBrick::Log.new(StringIO.new), AccessLog: []
    )
    @server.mount_proc('/api/v1/telemetry/') { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
  end

  def url
    "http://127.0.0.1:#{@server.config[:Port]}"
  end

  # Queue per-POST responses, consumed in order; then the default applies.
  def script(*steps)
    @mutex.synchronize { @script.concat(steps) }
  end

  def default=(step)
    @mutex.synchronize { @default = step }
  end

  # Answer the hung POST +index+ with +step+.
  def release(index, step = DEFAULT_STEP)
    @mutex.synchronize do
      @releases[index] = step
      @cv.broadcast
    end
  end

  def post_count
    @mutex.synchronize { @bodies.size }
  end

  def body(index)
    @mutex.synchronize { @bodies.fetch(index) }
  end

  def sha(index)
    Digest::SHA256.hexdigest(body(index))
  end

  def wait_for_posts(count, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until post_count >= count
      raise "stub saw #{post_count} POST(s), expected #{count}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end

  def close
    @mutex.synchronize do
      @closed = true
      @cv.broadcast
    end
    @server.shutdown
    @thread.join(2)
  end

  private

  def handle(req, res)
    raw = (req.body || '').b
    index, step = @mutex.synchronize do
      @bodies << raw
      [@bodies.size - 1, @script.shift || @default]
    end
    step = wait_for_release(index) if step[:hang]

    res.status = step.fetch(:status, 200)
    res['Retry-After'] = step[:retry_after].to_s if step[:retry_after]
    res['Content-Type'] = 'application/json'
    res.body = step.fetch(:body, '{}')
  end

  def wait_for_release(index)
    @mutex.synchronize do
      @cv.wait(@mutex) until @closed || @releases.key?(index)
      @releases.fetch(index, { status: 503 })
    end
  end
end
