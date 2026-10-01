# frozen_string_literal: true

require 'test_helper'

class DurationTest < Minitest::Test
  MINUTES_IN_SECONDS = 60
  HOURS_IN_SECONDS = 60 * MINUTES_IN_SECONDS
  DAYS_IN_SECONDS = 24 * HOURS_IN_SECONDS

  TESTS = [
    ['PT0M0S', 0],
    ['PT6M', 6 * MINUTES_IN_SECONDS],
    ['PT90S', 90],
    ['P1D', DAYS_IN_SECONDS],
    ['PT1M90.3S', MINUTES_IN_SECONDS + 90.3],
    ['PT1H', HOURS_IN_SECONDS],
    ['P1DT2H3M4S', DAYS_IN_SECONDS + (2 * HOURS_IN_SECONDS) + (3 * MINUTES_IN_SECONDS) + 4],
    ['PT1H30M', HOURS_IN_SECONDS + (30 * MINUTES_IN_SECONDS)],
    ['PT15M30S', (15 * MINUTES_IN_SECONDS) + 30],
    ['PT23H59M59S', (23 * HOURS_IN_SECONDS) + (59 * MINUTES_IN_SECONDS) + 59]
  ].freeze

  # Fractions are allowed on S only (qfg-2agi decision 1).
  INVALID = ['PT1.5M', 'P0.75D', 'PT1.3H', 'P1.5DT1.5M', 'garbage', 'xxPT5Sxx', 'PT5M3H', '-PT5S'].freeze

  def test_parsing
    TESTS.each do |test|
      assert_in_delta test[1], Quonfig::Duration.parse(test[0]), 1e-9, "Failed parsing #{test[0]}"
    end
  end

  def test_parse_raises_on_invalid
    INVALID.each do |value|
      assert_raises(ArgumentError, value) { Quonfig::Duration.parse(value) }
    end
  end
end
