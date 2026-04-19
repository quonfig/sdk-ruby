# frozen_string_literal: true

require 'test_helper'

class TestConfigLoader < Minitest::Test
  def setup
    super
    options = Quonfig::Options.new(
    )
    @loader = Quonfig::ConfigLoader.new(MockBaseClient.new(options))
  end





  def test_highwater
    assert_equal 0, @loader.highwater_mark
    @loader.set(PrefabProto::Config.new(id: 1, key: 'sample_int', rows: [config_row(PrefabProto::ConfigValue.new(int: 456))]),
                'test')
    assert_equal 1, @loader.highwater_mark

    @loader.set(PrefabProto::Config.new(id: 5, key: 'sample_int', rows: [config_row(PrefabProto::ConfigValue.new(int: 456))]),
                'test')
    assert_equal 5, @loader.highwater_mark
    @loader.set(PrefabProto::Config.new(id: 2, key: 'sample_int', rows: [config_row(PrefabProto::ConfigValue.new(int: 456))]),
                'test')
    assert_equal 5, @loader.highwater_mark
  end

  def test_keeps_most_recent
    assert_equal 0, @loader.highwater_mark
    @loader.set(PrefabProto::Config.new(id: 1, key: 'sample_int', rows: [config_row(PrefabProto::ConfigValue.new(int: 1))]),
                'test')
    assert_equal 1, @loader.highwater_mark
    should_be :int, 1, 'sample_int'

    @loader.set(PrefabProto::Config.new(id: 4, key: 'sample_int', rows: [config_row(PrefabProto::ConfigValue.new(int: 4))]),
                'test')
    assert_equal 4, @loader.highwater_mark
    should_be :int, 4, 'sample_int'

    @loader.set(PrefabProto::Config.new(id: 2, key: 'sample_int', rows: [config_row(PrefabProto::ConfigValue.new(int: 2))]),
                'test')
    assert_equal 4, @loader.highwater_mark
    should_be :int, 4, 'sample_int'
  end


  def test_api_deltas
    val = PrefabProto::ConfigValue.new(int: 456)
    config = PrefabProto::Config.new(key: 'sample_int', rows: [config_row(val)])
    @loader.set(config, 'test')

    configs = PrefabProto::Configs.new
    configs.configs << config
    assert_equal configs, @loader.get_api_deltas
  end

  def test_loading_tombstones_removes_entries
    val = PrefabProto::ConfigValue.new(int: 456)
    config = PrefabProto::Config.new(key: 'sample_int', rows: [config_row(val)], id: 2)
    @loader.set(config, 'test')

    config = PrefabProto::Config.new(key: 'sample_int', rows: [], id: 3)
    @loader.set(config, 'test')

    configs = PrefabProto::Configs.new
    assert_equal configs, @loader.get_api_deltas
  end

  private

  def should_be(type, value, key)
    assert_equal type, @loader.calc_config[key][:config].rows[0].values[0].value.type
    assert_equal value, @loader.calc_config[key][:config].rows[0].values[0].value.send(type)
  end

  def config_row(value)
    PrefabProto::ConfigRow.new(values: [PrefabProto::ConditionalValue.new(value: value)])
  end
end
