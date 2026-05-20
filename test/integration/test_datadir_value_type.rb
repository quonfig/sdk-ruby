# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/datadir_value_type.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestDatadirValueType < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store('datadir_value_type')
  end

  # datadir int config value is loaded as a number, not a string
  def test_datadir_int_config_value_is_loaded_as_a_number_not_a_string
    client = Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir, environment: 'Production')
    assert_equal 123, client.get('brand.new.int')
    raw_config = client.store.get('brand.new.int')
    refute_nil raw_config, 'store.get(brand.new.int) should be loaded'
    raw_value = raw_config['default']['rules'][0]['value']['value']
    assert_kind_of Numeric, raw_value,
                   "datadir loader must coerce brand.new.int to a number, got #{raw_value.class} (#{raw_value.inspect})"
  end

  # datadir double config value is loaded as a number, not a string
  def test_datadir_double_config_value_is_loaded_as_a_number_not_a_string
    client = Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir, environment: 'Production')
    assert_equal 9.95, client.get('my-double-key')
    raw_config = client.store.get('my-double-key')
    refute_nil raw_config, 'store.get(my-double-key) should be loaded'
    raw_value = raw_config['default']['rules'][0]['value']['value']
    assert_kind_of Numeric, raw_value,
                   "datadir loader must coerce my-double-key to a number, got #{raw_value.class} (#{raw_value.inspect})"
  end
end
