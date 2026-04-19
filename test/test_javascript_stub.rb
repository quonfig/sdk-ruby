# frozen_string_literal: true

require 'test_helper'

class JavascriptStubTest < Minitest::Test
  PROJECT_ENV_ID = 1
  DEFAULT_VALUE = 'default_value'
  DEFAULT_VALUE_CONFIG = PrefabProto::ConfigValue.new(string: DEFAULT_VALUE)
  TRUE_CONFIG = PrefabProto::ConfigValue.new(bool: true)
  FALSE_CONFIG = PrefabProto::ConfigValue.new(bool: false)
  DEFAULT_ROW = PrefabProto::ConfigRow.new(
    values: [
      PrefabProto::ConditionalValue.new(value: DEFAULT_VALUE_CONFIG)
    ]
  )

  def setup
    super

    log_level = PrefabProto::Config.new(
      id: 999,
      key: 'log-level',
      config_type: PrefabProto::ConfigType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::INFO)
            )
          ]
        )
      ]
    )

    config_for_sdk = PrefabProto::Config.new(
      id: 123,
      key: 'basic-config',
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [DEFAULT_ROW],
      send_to_client_sdk: true
    )

    config_not_for_sdk = PrefabProto::Config.new(
      id: 787,
      key: 'non-sdk-basic-config',
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [DEFAULT_ROW]
    )

    json_config = PrefabProto::Config.new(
      id: 234,
      key: 'json-config',
      config_type: PrefabProto::ConfigType::CONFIG,
      send_to_client_sdk: true,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(value: PrefabProto::ConfigValue.new(json: PrefabProto::Json.new(json: '{"key":"value"}')))
          ]
        )
      ]
    )

    duration_config = PrefabProto::Config.new(
      id: 236,
      key: 'duration-config',
      config_type: PrefabProto::ConfigType::CONFIG,
      send_to_client_sdk: true,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(value: PrefabProto::ConfigValue.new(duration: PrefabProto::IsoDuration.new(definition: "P4DT12H30M5S")))
          ]
        )
      ]
    )

    ff = PrefabProto::Config.new(
      id: 456,
      key: 'feature-flag',
      config_type: PrefabProto::ConfigType::FEATURE_FLAG,
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

    @client = new_client(
      config: [log_level, config_for_sdk, config_not_for_sdk, ff, json_config, duration_config],
      project_env_id: PROJECT_ENV_ID,
      collect_evaluation_summaries: true,
      context_upload_mode: :periodic_example,
      allow_telemetry_in_local_mode: true
    )
  end

  def test_bootstrap
    result = Quonfig::JavaScriptStub.new(@client).bootstrap({})


    File.open('/tmp/prefab_config.json', 'w') do |f|
      f.write(result)
    end
    assert_equal %(
window._prefabBootstrap = {
  evaluations: {"log-level":{"value":{"logLevel":"INFO"}},"basic-config":{"value":{"string":"default_value"}},"feature-flag":{"value":{"bool":false}},"json-config":{"value":{"json":"{\\"key\\":\\"value\\"}"}},"duration-config":{"value":{"duration":{"ms":390605000.0,"seconds":390605.0}}}},
  context: {}
}
    ).strip, result.strip

    result = Quonfig::JavaScriptStub.new(@client).bootstrap({ user: { email: 'gmail.com' } })

    File.open('/tmp/prefab_config.json', 'w') do |f|
      f.write(result)
    end

    assert_equal %(
window._prefabBootstrap = {
  evaluations: {"log-level":{"value":{"logLevel":"INFO"}},"basic-config":{"value":{"string":"default_value"}},"feature-flag":{"value":{"bool":true}},"json-config":{"value":{"json":"{\\"key\\":\\"value\\"}"}},"duration-config":{"value":{"duration":{"ms":390605000.0,"seconds":390605.0}}}},
  context: {"user":{"email":"gmail.com"}}
}

    ).strip, result.strip
  end

  def test_generate_stub
    result = Quonfig::JavaScriptStub.new(@client).generate_stub({})

    assert_equal %(
window.prefab = window.prefab || {};
window.prefab.config = {"log-level":"INFO","basic-config":"default_value","feature-flag":false,"json-config":"{\\"key\\":\\"value\\"}","duration-config":{"ms":390605000.0,"seconds":390605.0}};
window.prefab.get = function(key) {
  var value = window.prefab.config[key];

  return value;
};
window.prefab.isEnabled = function(key) {
  var value = window.prefab.config[key] === true;

  return value;
};
    ).strip, result.strip

    result = Quonfig::JavaScriptStub.new(@client).generate_stub({ user: { email: 'gmail.com' } }, 'myEvalCallback')

    assert_equal %(
window.prefab = window.prefab || {};
window.prefab.config = {"log-level":"INFO","basic-config":"default_value","feature-flag":true,"json-config":"{\\"key\\":\\"value\\"}","duration-config":{"ms":390605000.0,"seconds":390605.0}};
window.prefab.get = function(key) {
  var value = window.prefab.config[key];
  myEvalCallback(key, value);
  return value;
};
window.prefab.isEnabled = function(key) {
  var value = window.prefab.config[key] === true;
  myEvalCallback(key, value);
  return value;
};

    ).strip, result.strip
  end
end
