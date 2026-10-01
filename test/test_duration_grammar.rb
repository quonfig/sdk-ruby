# frozen_string_literal: true

require 'test_helper'
require 'yaml'

# Drives Quonfig::Duration against the shared grammar fixture
# integration-test-data/tests/duration/grammar.yaml (qfg-2agi.29), the ONE
# definition of which duration strings are valid and what they mean in ms.
class TestDurationGrammar < Minitest::Test
  FIXTURE = File.expand_path('../../integration-test-data/tests/duration/grammar.yaml', __dir__)

  def grammar
    @grammar ||= begin
      skip_or_fail_missing_fixture unless File.exist?(FIXTURE)
      YAML.safe_load_file(FIXTURE)
    end
  end

  def skip_or_fail_missing_fixture
    flunk "duration grammar fixture not found at #{FIXTURE} - clone quonfig/integration-test-data as a sibling of sdk-ruby."
  end

  def test_fixture_is_not_empty
    refute_empty grammar.fetch('valid')
    refute_empty grammar.fetch('invalid')
  end

  def test_valid_values_parse_to_exact_millis
    grammar.fetch('valid').each do |entry|
      actual = Quonfig::Duration.parse_millis(entry.fetch('value'))
      assert_kind_of Integer, actual, "parse_millis(#{entry['value'].inspect})"
      assert_equal entry.fetch('millis'), actual, "parse_millis(#{entry['value'].inspect})"
      assert Quonfig::Duration.valid?(entry.fetch('value')), "valid?(#{entry['value'].inspect})"
    end
  end

  def test_invalid_values_are_rejected
    grammar.fetch('invalid').each do |value|
      assert_nil Quonfig::Duration.parse_millis(value), "parse_millis(#{value.inspect}) must be nil"
      refute Quonfig::Duration.valid?(value), "valid?(#{value.inspect}) must be false"
    end
  end

  def test_non_strings_are_rejected
    [nil, 5000, 1.5, [], {}].each do |value|
      assert_nil Quonfig::Duration.parse_millis(value), "parse_millis(#{value.inspect}) must be nil"
    end
  end
end
