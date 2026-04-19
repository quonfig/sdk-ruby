# frozen_string_literal: true

require 'test_helper'
require 'integration_test_helpers'
require 'integration_test'
require 'yaml'

class TestIntegration < Minitest::Test
  IntegrationTestHelpers.find_integration_tests.map do |test_file|
    tests = YAML.load(File.read(test_file))['tests']
    test_names = []

    tests.each do |test|
      test['cases'].each do |test_case|
        new_name = "test_#{test['name']}_#{test_case['name']}"

        if test_names.include?(new_name)
          raise "Duplicate test name: #{new_name}"
        end

        test_names << new_name

        define_method(:"#{new_name}") do
          it = IntegrationTest.new(test_case)

          IntegrationTestHelpers.with_block_context_maybe(it.block_context) do
            case it.test_type
            when :raise
              err = assert_raises(it.expected[:error]) do
                it.test_client.send(it.func, *it.input)
              end
              assert_match(/#{it.expected[:message]}/, err.message)
            when :nil
              assert_nil it.test_client.send(it.func, *it.input)
            when :simple_equality
              if it.func == :enabled?
                flag, _default, context = *it.input
                assert_equal it.expected[:value], it.test_client.send(it.func, flag, context)
              else
                assert_equal it.expected[:value], it.test_client.send(it.func, *it.input)
              end
            when :log_level
              assert_equal it.expected[:value].to_sym, it.test_client.send(it.func, *it.input)
            when :telemetry
              aggregator, get_actual_data, expected = IntegrationTestHelpers.prepare_post_data(it)
              aggregator.sync

              wait_for -> { it.last_post_result&.status == 200 }

              assert_equal "/api/v1/telemetry", it.last_post_endpoint

              actual = get_actual_data[it.last_data_sent]

              expected.all? do |expected|
                assert actual.include?(expected), "#{actual} should include #{expected}"
              end
            when :duration
              assert_equal it.expected[:millis], it.test_client.send(it.func, *it.input).in_seconds * 1000
            else
              raise "Unknown test type: #{it.test_type}"
            end

            if test_case["name"].match(/doesn't raise on init timeout/)
              assert_logged [
                "Quonfig::ConfigClient -- Couldn't Initialize In 0.01. Key any-key. Returning what we have"
              ]
            end
          ensure
            it.teardown
          end
        end
      end
    end
  end
end
