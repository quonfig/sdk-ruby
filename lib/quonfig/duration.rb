# frozen_string_literal: true

module Quonfig
  # ISO-8601 duration parsing for the grammar every Quonfig SDK shares
  # (integration-test-data/tests/duration/grammar.yaml, qfg-2agi.29):
  #
  #   \AP(?:[0-9]+D)?(?:T(?:[0-9]+H)?(?:[0-9]+M)?(?:[0-9]+(?:\.[0-9]{1,9})?S)?)?\z
  #
  # plus: at least one component, no dangling T, a fraction only on S (at
  # most 9 digits), total magnitude <= P36500D. Anchored with \A/\z (Ruby's
  # ^/$ match at line boundaries) and [0-9] (never \d).
  #
  # Milliseconds use exact Rational arithmetic, rounded half up.
  class Duration
    PATTERN = /\AP(?:(?<days>[0-9]+)D)?(?:T(?<time>(?:(?<hours>[0-9]+)H)?(?:(?<minutes>[0-9]+)M)?(?:(?<seconds>[0-9]+(?:\.[0-9]{1,9})?)S)?))?\z/
    MINUTES_IN_SECONDS = 60
    HOURS_IN_SECONDS = 60 * MINUTES_IN_SECONDS
    DAYS_IN_SECONDS = 24 * HOURS_IN_SECONDS
    MAX_SECONDS = 36_500 * DAYS_IN_SECONDS

    def initialize(definition)
      @seconds = self.class.parse(definition)
    end

    # Integer milliseconds for a valid duration string, or nil when +definition+
    # is not a String or does not match the grammar.
    def self.parse_millis(definition)
      seconds = exact_seconds(definition)
      return nil if seconds.nil?

      (seconds * 1000).round(half: :up).to_i
    end

    def self.valid?(definition)
      !exact_seconds(definition).nil?
    end

    # Seconds as a Float. Raises ArgumentError when +definition+ is not a valid
    # duration (it used to return 0 for anything unparseable).
    def self.parse(definition)
      seconds = exact_seconds(definition)
      raise ArgumentError, "invalid ISO-8601 duration: #{definition.inspect}" if seconds.nil?

      seconds.to_f
    end

    # Exact Rational seconds, or nil when invalid.
    def self.exact_seconds(definition)
      return nil unless definition.is_a?(String)

      match = PATTERN.match(definition)
      return nil if match.nil?
      return nil if match[:days].nil? && match[:time].nil?
      return nil if match[:time] && match[:time].empty?

      total = (Integer(match[:days] || '0', 10) * DAYS_IN_SECONDS) +
              (Integer(match[:hours] || '0', 10) * HOURS_IN_SECONDS) +
              (Integer(match[:minutes] || '0', 10) * MINUTES_IN_SECONDS) +
              decimal_seconds(match[:seconds])
      return nil if total > MAX_SECONDS

      total
    end

    def self.decimal_seconds(text)
      return 0 if text.nil?

      whole, frac = text.split('.', 2)
      return Integer(whole, 10) if frac.nil?

      Integer(whole, 10) + Rational(Integer(frac, 10), 10**frac.length)
    end
    private_class_method :decimal_seconds

    def in_seconds
      @seconds
    end

    def in_minutes
      in_seconds / 60.0
    end

    def in_hours
      in_minutes / 60.0
    end

    def in_days
      in_hours / 24.0
    end

    def in_weeks
      in_days / 7.0
    end

    def to_i
      in_seconds.to_i
    end

    def to_f
      in_seconds.to_f
    end

    def as_json
      { ms: in_seconds * 1000, seconds: in_seconds }
    end
  end
end
