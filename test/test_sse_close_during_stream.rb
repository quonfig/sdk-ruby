# frozen_string_literal: true

require 'test_helper'
require 'socket'
require 'ostruct'

# qfg-yrly (audit 2026-10-16 M1): closing the SSE client during a LIVE stream
# must stop the worker thread promptly. Before the fix, the +break+ inside
# +read_body+ returned into Net::HTTPResponse#reading_body, which then drained
# the rest of the endless chunked stream with no block, so the worker stayed
# blocked in read_chunked forever and +close+ waited out its 2s join.
class TestSSECloseDuringStream < Minitest::Test
  # A chunked text/event-stream server that writes a keepalive every 0.1s
  # until the client goes away. Port 0: the OS picks a free port.
  class KeepaliveServer
    attr_reader :port

    def initialize(interval: 0.1, max_frames: nil)
      @interval = interval
      @max_frames = max_frames
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @threads = []
      @accept = Thread.new { accept_loop }
    end

    def stop
      @server.close
    rescue StandardError
      nil
    ensure
      @accept.kill
      @threads.each(&:kill)
    end

    private

    def accept_loop
      loop do
        sock = @server.accept
        @threads << Thread.new(sock) { |s| serve(s) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(sock)
      # read the request head
      while (line = sock.gets)
        break if line == "\r\n"
      end
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                 "Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\n\r\n")
      sent = 0
      loop do
        if @max_frames.nil? || sent < @max_frames
          payload = ": keepalive\n\n"
          sock.write("#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n")
          sent += 1
        end
        sleep @interval
      end
    rescue StandardError
      nil
    ensure
      begin
        sock.close
      rescue StandardError
        nil
      end
    end
  end

  def teardown
    @server&.stop
    super
  end

  def build_client
    @server ||= KeepaliveServer.new
    prefab_options = OpenStruct.new(sse_api_urls: ["http://127.0.0.1:#{@server.port}"], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    Quonfig::SSEConfigClient.new(prefab_options, config_loader)
  end

  def wait_until(timeout = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    true
  end

  def test_close_during_live_stream_stops_worker_promptly
    assert_close_stops_worker
  end

  # The worker is parked in a blocking read (one keepalive, then silence)
  # when close is called: closing the socket must still wake it.
  def test_close_while_blocked_in_read_stops_worker_promptly
    @server = KeepaliveServer.new(max_frames: 1)
    assert_close_stops_worker
  end

  private

  def assert_close_stops_worker
    leaked = 0
    slowest = 0.0
    10.times do
      client = build_client
      client.start { |_e, _ev, _s| }
      worker = client.instance_variable_get(:@worker)
      # wait until the stream is live: first frame delivered
      assert wait_until { client.alive? && client.instance_variable_get(:@active_http) }, 'stream never opened'
      sleep 0.25 # a few keepalives land

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.close
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      slowest = elapsed if elapsed > slowest
      leaked += 1 if worker.alive?
      worker.kill if worker.alive? # do not leak into the rest of the suite
    end

    assert_equal 0, leaked, 'SSE worker threads still alive after close on a live stream'
    assert_operator slowest, :<, 0.5, "close took #{slowest.round(2)}s on a live stream"
  end
end
