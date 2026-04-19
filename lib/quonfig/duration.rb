# frozen_string_literal: true

module Quonfig
  class Duration
    PATTERN = /P(?:(?<days>\d+(?:\.\d+)?)D)?(?:T(?:(?<hours>\d+(?:\.\d+)?)H)?(?:(?<minutes>\d+(?:\.\d+)?)M)?(?:(?<seconds>\d+(?:\.\d+)?)S)?)?/
    MINUTES_IN_SECONDS = 60
    HOURS_IN_SECONDS = 60 * MINUTES_IN_SECONDS
    DAYS_IN_SECONDS = 24 * HOURS_IN_SECONDS

    def initialize(definition)
      @seconds = self.class.parse(definition)
    end

    def self.parse(definition)
      match = PATTERN.match(definition)
      return 0 unless match

      days = match[:days]&.to_f || 0
      hours = match[:hours]&.to_f || 0
      minutes = match[:minutes]&.to_f || 0
      seconds = match[:seconds]&.to_f || 0

      (days * DAYS_IN_SECONDS + hours * HOURS_IN_SECONDS + minutes * MINUTES_IN_SECONDS + seconds)
    end

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
      { ms:  in_seconds * 1000, seconds: in_seconds }
    end
  end
end
