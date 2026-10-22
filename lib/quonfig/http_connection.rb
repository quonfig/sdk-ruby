# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'zlib'
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

    # Raised by #get when +max_body_bytes+ is set and the response body grows
    # past it (size-caps rule, qfg-6vno.20.5). Reading stops at the cap: the
    # body is streamed through a byte counter, never read whole and measured
    # afterwards. Not a Faraday error, so callers handle it explicitly.
    class BodyTooLargeError < StandardError
      attr_reader :max_bytes

      def initialize(max_bytes)
        @max_bytes = max_bytes
        super("response body exceeds the maximum size of #{max_bytes} bytes")
      end
    end

    # Size caps (qfg-6vno.20.5): a non-2xx body is read to at most this many
    # bytes, then reading stops and the connection is dropped. Callers never
    # use a non-2xx body (it is never logged), so a large one (a proxy error
    # page, a 401 with 17 MiB of junk) must not be read toward the 16 MiB cap.
    NON_2XX_BODY_READ_LIMIT = 1024

    # Raised from inside the body read to stop it early; never escapes.
    class StopReading < StandardError; end

    # Minimal response for the bounded path: the fields callers use.
    BoundedResponse = Struct.new(:status, :headers, :body)

    # +timeout_ms+ (qfg-7h5d.1.9): per-request bound applied to BOTH the connect
    # (open) and read phases of every request made through this connection, AND
    # (qfg-41nh.6) enforced as a wall-clock ceiling over the whole request. nil
    # leaves Faraday's defaults (no timeout) in place — preserving the prior
    # behavior for callers that don't pass one. The config-fetch path passes
    # Options#config_fetch_timeout_ms (sequential) or the hedge abort (hedged
    # legs) so a hung OR drip-feeding upstream aborts fast instead of blocking
    # the caller's whole init budget.
    #
    # +open_timeout_ms+ (qfg-y8je.8): a separate, usually shorter, bound on the
    # connect (open) phase — TCP connect plus TLS handshake. nil uses
    # +timeout_ms+ for it, as before. The telemetry reporter passes 5s here and
    # 15s as +timeout_ms+.
    #
    # +max_body_bytes+ (qfg-6vno.20.5): when set, #get streams the body through
    # a counter and raises BodyTooLargeError as soon as it passes this many
    # bytes, so memory stays bounded near the cap. nil reads the body whole,
    # as before. The config fetch passes ConfigLoader::MAX_CONFIG_BODY_BYTES.
    def initialize(uri, sdk_key, timeout_ms: nil, open_timeout_ms: nil, max_body_bytes: nil)
      @uri = uri
      @sdk_key = sdk_key
      @timeout_ms = timeout_ms
      @open_timeout_ms = open_timeout_ms
      @max_body_bytes = max_body_bytes
    end

    attr_reader :uri

    def get(path, headers = {})
      return with_wall_clock_deadline { connection(headers).get(path) } unless @max_body_bytes

      get_bounded(path, headers)
    end

    # A String +body+ is sent verbatim (the telemetry reporter resends a
    # retained batch byte-for-byte); anything else is serialized as JSON.
    def post(path, body)
      payload = body.is_a?(String) ? body : body.to_json
      with_wall_clock_deadline { connection.post(path, payload) }
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
        conn.options.open_timeout = @open_timeout_ms / 1000.0 if @open_timeout_ms
      end
    end

    private

    # The bounded GET runs on Net::HTTP directly, because it needs the status
    # BEFORE the body is read: a 2xx body is streamed through a counter that
    # raises BodyTooLargeError past +max_body_bytes+; a non-2xx body is read to
    # at most NON_2XX_BODY_READ_LIMIT bytes. Faraday 1.x's +on_data+ gives no
    # status to the callback, so it cannot tell the two apart. URL, headers and
    # proxy still come from the Faraday connection, so the request is the same.
    # Transport errors are re-raised as the Faraday errors callers rescue.
    def get_bounded(path, headers)
      with_wall_clock_deadline { net_http_get_bounded(path, headers) }
    end

    def net_http_get_bounded(path, headers)
      conn = connection(headers)
      url = conn.build_exclusive_url(path)
      req = Net::HTTP::Get.new(url.request_uri)
      conn.headers.each { |k, v| req[k] = v }
      result = nil
      begin
        bounded_http(conn, url).start do |http|
          http.request(req) do |res|
            result = BoundedResponse.new(res.code.to_i, response_headers(res), +''.b)
            read_bounded_body(res, result)
          end
        end
      rescue StopReading
        nil
      end
      result.body.force_encoding(Encoding::UTF_8)
      result
    rescue BodyTooLargeError, Faraday::Error
      raise
    rescue Timeout::Error, Errno::ETIMEDOUT => e
      raise Faraday::TimeoutError, e
    rescue IOError, SystemCallError, SocketError, Net::ProtocolError, Net::HTTPBadResponse,
           Net::HTTPHeaderSyntaxError, Zlib::Error, OpenSSL::SSL::SSLError => e
      raise Faraday::ConnectionFailed, e
    end

    def bounded_http(conn, url)
      proxy = conn.proxy
      http = if proxy
               Net::HTTP.new(url.hostname, url.port, proxy.uri.hostname, proxy.uri.port, proxy.user, proxy.password)
             else
               Net::HTTP.new(url.hostname, url.port, nil)
             end
      http.use_ssl = (url.scheme == 'https')
      if @timeout_ms
        http.open_timeout = @timeout_ms / 1000.0
        http.read_timeout = @timeout_ms / 1000.0
      end
      http.open_timeout = @open_timeout_ms / 1000.0 if @open_timeout_ms
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      http
    end

    def response_headers(res)
      headers = Faraday::Utils::Headers.new
      res.each_header { |k, v| headers[k] = v }
      headers
    end

    # Reading stops at the limit: the chunk that would cross it is not kept.
    def read_bounded_body(res, result)
      buf = result.body
      if (200..299).cover?(result.status)
        max = @max_body_bytes
        res.read_body do |chunk|
          raise BodyTooLargeError, max if buf.bytesize + chunk.bytesize > max

          buf << chunk.b
        end
      else
        res.read_body do |chunk|
          buf << chunk.b.byteslice(0, NON_2XX_BODY_READ_LIMIT - buf.bytesize)
          raise StopReading if buf.bytesize >= NON_2XX_BODY_READ_LIMIT
        end
      end
    end

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
                      "wall-clock per-request deadline #{deadline_s}s exceeded for #{Quonfig::ConfigLoader.redact_userinfo(@uri)}") do
        block.call
      end
    end

    def auth_header
      "Basic #{Base64.strict_encode64("1:#{@sdk_key}")}"
    end
  end
end
