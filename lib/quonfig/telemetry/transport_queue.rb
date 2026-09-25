# frozen_string_literal: true

require 'time'

module Quonfig
  module Telemetry
    # Monotonic milliseconds for the telemetry transport: the 30s floor,
    # Retry-After, retained-batch age and the WARN cadence all read it. Tests
    # inject a manual clock through TelemetryReporter.build(clock:).
    module MonotonicClock
      def self.now_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end

    # Telemetry transport policy (qfg-y8je.8; policy P1-P10 in
    # project/plans/2026-09-24-sdk-telemetry-transport-policy.md, contract tests
    # in integration-test-data/chaos/telemetry-transport-contract.md; mirrors
    # sdk-node's src/telemetry/transportQueue.ts).
    #
    # Owns the retained queue of serialized batches, the send gate (30s floor
    # after a failure + Retry-After), the drain loop, disable-on-auth and the P7
    # logging episodes. It knows nothing about aggregators or payload shape: it
    # stores and resends opaque bytes, never re-serializing or merging them.
    #
    # Not thread-safe on its own: TelemetryReporter serializes every call under
    # its tick mutex, which is also what keeps one POST in flight (P2).
    class TransportQueue
      LOG = Quonfig::InternalLogger.new(self)

      # No send sooner than this after a failed POST (P4).
      RESEND_FLOOR_MS = 30_000
      # Retry-After is honored up to this (P4).
      RETRY_AFTER_CAP_MS = 600_000
      # At most one drop WARN per this interval while dropping continues (P7).
      DROP_WARN_INTERVAL_MS = 600_000
      # close() gives the live window one POST with this deadline (P8).
      SHUTDOWN_FLUSH_DEADLINE_MS = 5_000

      # Outcome of one POST that got an HTTP response.
      Result = Struct.new(:status, :retry_after, :body_snippet, keyword_init: true)

      Batch = Struct.new(:body, :bytes, :created_at, :oversize, keyword_init: true)

      # 2xx -> :ok; 401, 403, 404 -> :auth; 408, 429, 5xx -> :retryable; every
      # other status (other 4xx, 3xx, 1xx) -> :rejected (P3).
      def self.classify_status(status)
        return :ok if status >= 200 && status < 300
        return :auth if [401, 403, 404].include?(status)
        return :retryable if [408, 429].include?(status) || (status >= 500 && status < 600)

        :rejected
      end

      # Parse a Retry-After header into a wait in ms: delta-seconds, or an
      # HTTP-date relative to now (past dates -> 0). Unparseable -> nil.
      # Clamped to RETRY_AFTER_CAP_MS.
      def self.parse_retry_after_ms(header, wall_now: Time.now)
        return nil if header.nil?

        value = header.to_s.strip
        return nil if value.empty?

        ms =
          if value.match?(/\A\d+\z/)
            value.to_i * 1000
          else
            begin
              [((Time.httpdate(value) - wall_now) * 1000).round, 0].max
            rescue ArgumentError
              return nil
            end
          end
        [ms, RETRY_AFTER_CAP_MS].min
      end

      # +sender+ is called as +sender.call(body, timeout_ms)+ and returns a
      # Result, or raises (a Faraday/Timeout error for a timeout, anything else
      # for a network failure).
      def initialize(sender:, telemetry_url:, timeout_ms:, max_retained_batches:,
                     max_retained_bytes:, max_retained_age_ms:, clock: MonotonicClock,
                     on_disabled: nil)
        @sender = sender
        @telemetry_url = telemetry_url
        @timeout_ms = timeout_ms
        @max_retained_batches = max_retained_batches
        @max_retained_bytes = max_retained_bytes
        @max_retained_age_ms = max_retained_age_ms
        @clock = clock
        @on_disabled = on_disabled

        @queue = []
        @in_flight = false
        @last_failure_at = nil
        @retry_after_until = nil
        @disabled = false

        # Outage episode (P7).
        @failures_since_success = 0
        @first_failure_at = nil
        @last_result = nil
        @last_drop_warn_at = nil
        @drops_since_warn = 0
        @drops_this_outage = 0

        # Rejected-batch (other 4xx) cadence.
        @last_reject_error_at = nil
        @rejects_since_error = 0
      end

      def in_flight? = @in_flight
      def disabled? = @disabled

      # Every queued batch, including a not-yet-sent oversize one.
      def retained_count = @queue.size

      def retained_bytes = @queue.sum(&:bytes)

      # Discard batches older than the max age (strictly greater). Tick step 2.
      def expire
        now = @clock.now_ms
        while (head = @queue.first) && now - head.created_at > @max_retained_age_ms
          @queue.shift
          record_drop("batch older than #{(@max_retained_age_ms / 60_000.0).round} min")
        end
      end

      # The 30s floor after a failure and any Retry-After have both elapsed.
      # Tick step 3.
      def send_allowed?
        now = @clock.now_ms
        return false if @last_failure_at && now < @last_failure_at + RESEND_FLOOR_MS
        return false if @retry_after_until && now < @retry_after_until

        true
      end

      # Append a serialized window and enforce the caps, dropping oldest. An
      # oversize batch is never counted against the caps and never evicted by
      # them: it is sent once and then dropped (see #drain). Tick step 4.
      def append(body)
        oversize = body.bytesize > @max_retained_bytes
        @queue << Batch.new(body: body, bytes: body.bytesize, created_at: @clock.now_ms, oversize: oversize)

        kept = @queue.reject(&:oversize)
        count = kept.size
        bytes = kept.sum(&:bytes)
        while count > @max_retained_batches || bytes > @max_retained_bytes
          index = @queue.index { |b| !b.oversize }
          break if index.nil?

          evicted = @queue.delete_at(index)
          count -= 1
          bytes -= evicted.bytes
          record_drop('retained queue full')
        end
      end

      # POST queued batches oldest-first, one at a time; stop at the first
      # failure. Tick step 5.
      def drain
        until @queue.empty? || @disabled
          batch = @queue.first
          outcome = post(batch.body, @timeout_ms)

          if outcome.is_a?(String)
            on_retryable_failure(batch, outcome, nil)
            break
          end

          case self.class.classify_status(outcome.status)
          when :ok
            @queue.shift
            on_success
          when :retryable
            on_retryable_failure(batch, outcome.status.to_s, outcome.retry_after)
            break
          when :auth
            disable(outcome.status)
            return
          else
            # Rejected: drop this batch, report, carry on with the next one.
            @queue.shift
            on_rejected(outcome.status, batch.bytes, outcome.body_snippet)
          end
        end

        # Oversize batches are never carried across ticks.
        @queue.select(&:oversize).each do |batch|
          remove(batch)
          record_drop('batch larger than the byte cap')
        end
      end

      # close(): one POST of the live window bounded by +deadline_ms+. Never
      # retains, never touches the outage episode, never raises.
      def send_final(body, deadline_ms)
        outcome = post(body, deadline_ms)
        result =
          if outcome.is_a?(String)
            outcome
          elsif self.class.classify_status(outcome.status) != :ok
            outcome.status.to_s
          end
        return if result.nil?

        LOG.debug "Telemetry final flush at shutdown failed (#{result}); #{body.bytesize} bytes dropped, " \
                  "#{retained_count} retained batch(es) abandoned"
      end

      private

      # Remove by identity (two batches may carry equal bytes).
      def remove(batch)
        @queue.reject! { |b| b.equal?(batch) }
      end

      # One POST. Returns a Result, or a String describing a request that got
      # no HTTP response ("timeout", "network error: ...").
      def post(body, timeout_ms)
        @in_flight = true
        @sender.call(body, timeout_ms)
      rescue Faraday::TimeoutError, Timeout::Error
        'timeout'
      rescue StandardError => e
        "network error: #{e.class}: #{e.message}"
      ensure
        @in_flight = false
      end

      def on_success
        return if @failures_since_success.zero?

        seconds = ((@clock.now_ms - (@first_failure_at || @clock.now_ms)) / 1000.0).round
        LOG.info "Telemetry recovered: POST succeeded after #{@failures_since_success} failed attempt(s) " \
                 "over #{seconds}s; #{@drops_this_outage} batch(es) were dropped."
        @failures_since_success = 0
        @first_failure_at = nil
        @drops_this_outage = 0
        @last_drop_warn_at = nil
        @drops_since_warn = 0
      end

      def on_retryable_failure(batch, result, retry_after)
        now = @clock.now_ms
        @failures_since_success += 1
        @first_failure_at ||= now
        @last_failure_at = now
        @last_result = result
        wait = self.class.parse_retry_after_ms(retry_after)
        @retry_after_until = now + wait if wait

        next_ms = [@last_failure_at + RESEND_FLOOR_MS, @retry_after_until || 0].max - now
        LOG.debug "Telemetry POST failed (#{result}); #{retained_count} batch(es) / #{retained_bytes} bytes " \
                  "retained, next send in >= #{(next_ms / 1000.0).ceil}s"

        return unless batch.oversize

        remove(batch)
        record_drop('batch larger than the byte cap')
      end

      def disable(status)
        hint = status == 404 ? 'wrong telemetry_url' : 'the SDK key was rejected'
        LOG.error "Telemetry disabled for this process: #{@telemetry_url} answered #{status} (#{hint}). " \
                  'Flag evaluation is unaffected.'
        @queue.clear
        @disabled = true
        @on_disabled&.call
      end

      def on_rejected(status, bytes, body_snippet)
        now = @clock.now_ms
        if @last_reject_error_at.nil? || now - @last_reject_error_at >= DROP_WARN_INTERVAL_MS
          more = @rejects_since_error.positive? ? ", #{@rejects_since_error} more since the last report" : ''
          LOG.error "Telemetry batch rejected with #{status} and dropped (#{bytes} bytes#{more}): " \
                    "#{body_snippet}. This is likely an SDK bug; please report it."
          @last_reject_error_at = now
          @rejects_since_error = 0
        else
          @rejects_since_error += 1
          LOG.debug "Telemetry batch rejected with #{status} and dropped (#{bytes} bytes)"
        end
      end

      def record_drop(reason)
        now = @clock.now_ms
        @drops_since_warn += 1
        @drops_this_outage += 1
        last_result = @last_result || 'none'
        if @last_drop_warn_at.nil?
          LOG.warn "Telemetry is dropping data: #{reason} (last POST result: #{last_result}). " \
                   "#{@drops_this_outage} batch(es) dropped so far; retained queue " \
                   "#{retained_count}/#{@max_retained_batches} batches, #{retained_bytes} bytes. " \
                   'Flag evaluation is unaffected; further drops log at debug with a summary every 10 min.'
          @last_drop_warn_at = now
          @drops_since_warn = 0
        elsif now - @last_drop_warn_at >= DROP_WARN_INTERVAL_MS
          minutes = ((now - @last_drop_warn_at) / 60_000.0).round
          LOG.warn "Telemetry still dropping data: #{@drops_since_warn} batch(es) dropped in the last " \
                   "#{minutes} min (last POST result: #{last_result}); retained queue #{retained_count} " \
                   "batches, #{retained_bytes} bytes."
          @last_drop_warn_at = now
          @drops_since_warn = 0
        else
          LOG.debug "Telemetry dropped a batch: #{reason}; #{@drops_since_warn} since the last warning"
        end
      end
    end
  end
end
