# frozen_string_literal: true

require 'test_helper'

class TestClient < Minitest::Test
  LOCAL_ONLY = Quonfig::Options::DATASOURCES::LOCAL_ONLY

  PROJECT_ENV_ID = 1
  KEY = 'the-key'
  DEFAULT_VALUE = 'default_value'
  DESIRED_VALUE = 'desired_value'

  IRRELEVANT = 'this should never show up'

  DEFAULT_VALUE_CONFIG = PrefabProto::ConfigValue.new(string: DEFAULT_VALUE)
  DESIRED_VALUE_CONFIG = PrefabProto::ConfigValue.new(string: DESIRED_VALUE)

  TRUE_CONFIG = PrefabProto::ConfigValue.new(bool: true)
  FALSE_CONFIG = PrefabProto::ConfigValue.new(bool: false)

  DEFAULT_ROW = PrefabProto::ConfigRow.new(
    values: [
      PrefabProto::ConditionalValue.new(value: DEFAULT_VALUE_CONFIG)
    ]
  )



  def test_get_with_missing_default
    client = new_client
    # it raises by default
    err = assert_raises(Quonfig::Errors::MissingDefaultError) do
      assert_nil client.get('missing_value')
    end

    assert_match(/No value found for key/, err.message)
    assert_match(/on_no_default/, err.message)

    # you can opt-in to return `nil` instead
    client = new_client(on_no_default: Quonfig::Options::ON_NO_DEFAULT::RETURN_NIL)
    assert_nil client.get('missing_value')
  end





  def test_initialization_with_an_options_object
    options_hash = {
      namespace: 'test-namespace',
      prefab_datasources: LOCAL_ONLY
    }

    options = Quonfig::Options.new(options_hash)

    client = Quonfig::Client.new(options)

    assert_equal client.namespace, 'test-namespace'
  end

  def test_initialization_with_a_hash
    options_hash = {
      namespace: 'test-namespace',
      prefab_datasources: LOCAL_ONLY
    }

    client = Quonfig::Client.new(options_hash)

    assert_equal client.namespace, 'test-namespace'
  end

  def test_evaluation_summary_aggregator
    fake_api_key = '123-development-yourapikey-SDK'

    # it is nil by default
    assert_nil new_client(sdk_key: fake_api_key).evaluation_summary_aggregator

    # it is nil when local_only even if collect_max_evaluation_summaries is true
    assert_nil new_client(prefab_datasources: LOCAL_ONLY,
                                  collect_evaluation_summaries: true, ).evaluation_summary_aggregator

    # it is nil when collect_max_evaluation_summaries is false
    assert_nil new_client(sdk_key: fake_api_key,
                                  prefab_datasources: :all,
                                  collect_evaluation_summaries: false).evaluation_summary_aggregator

    # it is not nil when collect_max_evaluation_summaries is true and the datasource is not local_only
    assert_equal Quonfig::EvaluationSummaryAggregator,
                 new_client(sdk_key: fake_api_key,
                            prefab_datasources: :all,
                            collect_evaluation_summaries: true).evaluation_summary_aggregator.class

    assert_logged [
      "Quonfig::ConfigClient -- No success loading checkpoints"
    ]
  end

  def test_get_with_basic_value
    config = basic_value_config
    client = new_client(config: config, project_env_id: PROJECT_ENV_ID, collect_evaluation_summaries: true,
                        context_upload_mode: :periodic_example, allow_telemetry_in_local_mode: true)

    assert_equal DESIRED_VALUE, client.get(config.key, IRRELEVANT, 'user' => { 'key' => 99 })

    assert_summary client, {
      [KEY, :CONFIG] => {
        {
          config_id: config.id,
          config_row_index: 0,
          selected_value: DESIRED_VALUE_CONFIG,
          conditional_value_index: 0,
          weighted_value_index: nil,
          selected_index: nil
        } => 1
      }
    }

    assert_example_contexts client, [Quonfig::Context.new({ user: { 'key' => 99 } })]
  end

  def test_get_with_basic_value_with_context
    config = basic_value_config
    client = new_client(config: config, project_env_id: PROJECT_ENV_ID, collect_evaluation_summaries: true,
                        context_upload_mode: :periodic_example, allow_telemetry_in_local_mode: true)

    client.with_context('user' => { 'key' => 99 }) do
      assert_equal DESIRED_VALUE, client.get(config.key)
    end

    assert_summary client, {
      [KEY, :CONFIG] => {
        {
          config_id: config.id,
          config_row_index: 0,
          selected_value: DESIRED_VALUE_CONFIG,
          conditional_value_index: 0,
          weighted_value_index: nil,
          selected_index: nil
        } => 1
      }
    }

    assert_example_contexts client, [Quonfig::Context.new({ user: { 'key' => 99 } })]
  end

  def test_get_with_weighted_values
    config = PrefabProto::Config.new(
      id: 123,
      key: KEY,
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)],
              value: PrefabProto::ConfigValue.new(weighted_values: weighted_values([['abc', 98], ['def', 1],
                                                                                    ['ghi', 1]]))
            )
          ]
        )
      ]
    )

    client = new_client(config: config, project_env_id: PROJECT_ENV_ID, collect_evaluation_summaries: true,
                       context_upload_mode: :periodic_example, allow_telemetry_in_local_mode: true)

    2.times do
      assert_equal 'abc', client.get(config.key, IRRELEVANT, 'user' => { 'key' => '1' })
    end

    3.times do
      assert_equal 'def', client.get(config.key, IRRELEVANT, 'user' => { 'key' => '12' })
    end

    assert_equal 'ghi',
                 client.get(config.key, IRRELEVANT, 'user' => { 'key' => '4', admin: true })

    assert_summary client, {
      [KEY, :CONFIG] => {
        {
          config_id: config.id,
          config_row_index: 0,
          selected_value: PrefabProto::ConfigValue.new(string: 'abc'),
          conditional_value_index: 0,
          weighted_value_index: 0,
          selected_index: nil
        } => 2,

        {
          config_id: config.id,
          config_row_index: 0,
          selected_value: PrefabProto::ConfigValue.new(string: 'def'),
          conditional_value_index: 0,
          weighted_value_index: 1,
          selected_index: nil
        } => 3,

        {
          config_id: config.id,
          config_row_index: 0,
          selected_value: PrefabProto::ConfigValue.new(string: 'ghi'),
          conditional_value_index: 0,
          weighted_value_index: 2,
          selected_index: nil
        } => 1
      }
    }

    assert_example_contexts client, [
      Quonfig::Context.new(user: { 'key' => '1' }),
      Quonfig::Context.new(user: { 'key' => '12' }),
      Quonfig::Context.new(user: { 'key' => '4', admin: true })
    ]
  end

  def test_in_seg
    segment_key = 'segment_key'

    segment_config = PrefabProto::Config.new(
      config_type: PrefabProto::ConfigType::SEGMENT,
      key: segment_key,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: TRUE_CONFIG,
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_ENDS_WITH_ONE_OF,
                  value_to_match: string_list(['hotmail.com', 'gmail.com']),
                  property_name: 'user.email'
                )
              ]
            ),
            PrefabProto::ConditionalValue.new(value: FALSE_CONFIG)
          ]
        )
      ]
    )

    config = PrefabProto::Config.new(
      key: KEY,
      rows: [
        DEFAULT_ROW,

        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::IN_SEG,
                  value_to_match: PrefabProto::ConfigValue.new(string: segment_key)
                )
              ],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )

    client = new_client(config: [config, segment_config], project_env_id: PROJECT_ENV_ID,
                        collect_evaluation_summaries: true, context_upload_mode: :periodic_example, allow_telemetry_in_local_mode: true)

    assert_equal DEFAULT_VALUE, client.get(config.key)
    assert_equal DEFAULT_VALUE,
                 client.get(config.key, IRRELEVANT, user: { key: 'abc', email: 'example@prefab.cloud' })
    assert_equal DESIRED_VALUE, client.get(config.key, IRRELEVANT, user: { key: 'def', email: 'example@hotmail.com' })

    assert_summary client, {
      [segment_key, :SEGMENT] => {
        { config_id: 0, config_row_index: 0, conditional_value_index: 1, selected_value: FALSE_CONFIG,
          weighted_value_index: nil, selected_index: nil } => 2,
        { config_id: 0, config_row_index: 0, conditional_value_index: 0, selected_value: TRUE_CONFIG,
          weighted_value_index: nil, selected_index: nil } => 1
      },
      [KEY, :NOT_SET_CONFIG_TYPE] => {
        { config_id: 0, config_row_index: 1, conditional_value_index: 0, selected_value: DEFAULT_VALUE_CONFIG,
          weighted_value_index: nil, selected_index: nil } => 2,
        { config_id: 0, config_row_index: 0, conditional_value_index: 0, selected_value: DESIRED_VALUE_CONFIG,
          weighted_value_index: nil, selected_index: nil } => 1
      }
    }

    assert_example_contexts client, [
      Quonfig::Context.new(user: { key: 'abc', email: 'example@prefab.cloud' }),
      Quonfig::Context.new(user: { key: 'def', email: 'example@hotmail.com' })
    ]
  end

  def test_get_log_level
    config = PrefabProto::Config.new(
      id: 999,
      key: 'log-level',
      config_type: PrefabProto::ConfigType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::INFO)
            )
          ]
        )
      ]
    )

    client = new_client(config: config, project_env_id: PROJECT_ENV_ID,
                        collect_evaluation_summaries: true, allow_telemetry_in_local_mode: true)

    assert_equal :INFO, client.get(config.key, IRRELEVANT)

    # nothing is summarized for log levels
    assert_summary client, {}
  end



  def test_with_datafile
    datafile = "#{Dir.pwd}/test/fixtures/datafile.json"
    client = new_client(datafile: datafile, prefab_datasources: :all)

    assert client.get('flag.list.environments')
    assert_equal "hello world", client.get('my.test.string')
  end

  private

  def basic_value_config
    PrefabProto::Config.new(
      id: 123,
      key: KEY,
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        DEFAULT_ROW,
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [PrefabProto::Criterion.new(operator: PrefabProto::Criterion::CriterionOperator::ALWAYS_TRUE)],
              value: DESIRED_VALUE_CONFIG
            )
          ]
        )
      ]
    )
  end
end
