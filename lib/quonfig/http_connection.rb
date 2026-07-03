# frozen_string_literal: true

require 'base64'
require 'json'
require 'timeout'

module Quonfig
  class HttpConnection
    SDK_VERSION = "ruby-#{Quonfig::VERSION}".freeze

    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'X-Quonfig-SDK-Version' => SDK_VERSION
    }.freeze

    # qfg-41nh.6 (WS2.4): headroom added to +timeout_ms+ to form the WALL-CLOCK
    # ceiling for the whole request. Faraday's open/read timeouts are per-phase
    # and — on the Net::HTTP adapter — per-READ: every byte that arrives resets
    # the read deadline, so a slow-drip upstream (one byte per interval) holds a
    # "bounded" request open indefinitely and wedges the caller (init fetch,
    # fallback poll tick, hedge drain). The wall clock is the true per-leg abort
    # (sdk-go's per-leg context deadline is wall-clock). The headroom keeps
    # Faraday's own, more specific phase timeouts winning the simple-stall race;
    # the wall clock only fires on drip-feed pathologies that per-read deadlines
    # structurally cannot catch.
    WALL_CLOCK_HEADROOM_S = 0.25

    # +timeout_ms+ (qfg-7h5d.1.9): per-request bound applied to BOTH the connect
    # (open) and read phases of every request made through this connection, AND
    # (qfg-41nh.6) enforced as a wall-clock ceiling over the whole request. nil
    # leaves Faraday's defaults (no timeout) in place — preserving the prior
    # behavior for callers that don't pass one. The config-fetch path passes
    # Options#config_fetch_timeout_ms (sequential) or the hedge abort (hedged
    # legs) so a hung OR drip-feeding upstream aborts fast instead of blocking
    # the caller's whole init budget.
    def initialize(uri, sdk_key, timeout_ms: nil)
      @uri = uri
      @sdk_key = sdk_key
      @timeout_ms = timeout_ms
    end

    attr_reader :uri

    def get(path, headers = {})
      with_wall_clock_deadline { connection(headers).get(path) }
    end

    def post(path, body)
      with_wall_clock_deadline { connection.post(path, body.to_json) }
    end

    def connection(headers = {})
      merged = JSON_HEADERS.merge('Authorization' => auth_header).merge(headers)
      Faraday.new(@uri) do |conn|
        conn.headers.merge!(merged)
        if @timeout_ms
          seconds = @timeout_ms / 1000.0
          # open_timeout bounds the TCP connect; timeout bounds the read. A
          # 'timeout' toxic accepts the connection but never sends bytes, so the
          # read deadline is the one that fires — set both so a refused/slow
          # connect is bounded too.
          conn.options.open_timeout = seconds
          conn.options.timeout = seconds
        end
      end
    end

    private

    # Enforce +timeout_ms+ (+ headroom) as a wall-clock deadline over the whole
    # request. Timeout.timeout is the codebase's accepted backstop pattern (the
    # init path wraps fetch! the same way in Client#perform_initial_fetch); a
    # deadline check inside the read loop isn't practical here because Faraday
    # 1.x's Net::HTTP adapter exposes no per-chunk streaming hook. Raises
    # Faraday::TimeoutError so callers' existing timeout rescue paths apply
    # unchanged. No-op when no timeout_ms was configured.
    def with_wall_clock_deadline(&block)
      return block.call unless @timeout_ms

      deadline_s = (@timeout_ms / 1000.0) + WALL_CLOCK_HEADROOM_S
      Timeout.timeout(deadline_s, Faraday::TimeoutError,
                      "wall-clock per-request deadline #{deadline_s}s exceeded for #{@uri}") do
        block.call
      end
    end

    def auth_header
      "Basic #{Base64.strict_encode64("1:#{@sdk_key}")}"
    end
  end
end
