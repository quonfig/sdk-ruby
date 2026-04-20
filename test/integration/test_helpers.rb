# frozen_string_literal: true

require 'json'
require 'quonfig'

# Integration-test environment — the generated tests read these the same way
# the SDK does at runtime. Mirrors sdk-node/test/integration/setup.ts and
# sdk-go/internal/fixtures/test_helpers_test.go so behavior stays consistent
# across SDKs.
ENV['PREFAB_INTEGRATION_TEST_ENCRYPTION_KEY'] =
  'c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221'
ENV['IS_A_NUMBER'] = '1234'
ENV['NOT_A_NUMBER'] = 'not_a_number'
ENV.delete('MISSING_ENV_VAR')

# Shared fixture loader + resolver factory for the generated integration
# tests in sdk-ruby/test/integration/test_*.rb (qfg-dk6.23/.24). The evaluator
# wired up here still delegates to Quonfig::CriteriaEvaluator — once
# qfg-dk6.10 ports the criterion operators to the JSON Criterion type,
# generated tests will resolve end-to-end. Until then build_store simply
# parses the JSON fixtures into the ConfigStore.
module IntegrationTestHelpers
  DATA_DIR = File.expand_path(
    '../../../integration-test-data/data/integration-tests',
    __dir__
  )
  ENV_ID = 'Production'
  CONFIG_SUBDIRS = %w[configs feature-flags segments log-levels schemas].freeze

  def self.data_dir
    DATA_DIR
  end

  # fixture_name matches the generator's YAML suite name (e.g. 'get',
  # 'enabled'). Every suite shares the same config corpus — mirrors
  # sdk-node/sdk-go, which also build a single store for the whole run —
  # so the name is advisory. Accepting it keeps the call shape the task
  # spec asks for and leaves room for per-suite overlays later.
  def self.build_store(_fixture_name = nil)
    unless Dir.exist?(DATA_DIR)
      raise "[integration tests] fixtures not found at #{DATA_DIR} — " \
            'clone quonfig/integration-test-data as a sibling of sdk-ruby.'
    end

    store = Quonfig::ConfigStore.new
    CONFIG_SUBDIRS.each do |subdir|
      dir = File.join(DATA_DIR, subdir)
      next unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.json')).each do |path|
        raw = JSON.parse(File.read(path))
        cfg = to_config_response(raw)
        key = cfg[:key]
        next if key.nil? || key.empty?

        store.set(key, cfg)
      end
    end
    store
  end

  def self.build_resolver(store)
    evaluator = Quonfig::Evaluator.new(store, env_id: ENV_ID)
    Quonfig::Resolver.new(store, evaluator)
  end

  # Resolve +key+ against +context+ and assert the unwrapped value (and,
  # when present, its reported value_type) match. Generated tests call
  # this; keep the failure message specific so diffs are readable.
  def self.assert_resolved(resolver, key, context, expected_value, expected_type = nil)
    ctx = context.is_a?(Quonfig::Context) ? context : Quonfig::Context.new(context || {})
    result = resolver.get(key, ctx)
    raise Minitest::Assertion, "No evaluation returned for key #{key.inspect}" if result.nil?

    actual = if result.respond_to?(:unwrapped_value)
               result.unwrapped_value
             elsif result.respond_to?(:value)
               v = result.value
               v.respond_to?(:string) ? v.string : v
             else
               result
             end

    unless actual == expected_value
      raise Minitest::Assertion,
            "#{key}: expected #{expected_value.inspect} (#{expected_type}), got #{actual.inspect}"
    end

    if expected_type && result.respond_to?(:value_type)
      unless result.value_type.to_s == expected_type.to_s
        raise Minitest::Assertion,
              "#{key}: expected type #{expected_type}, got #{result.value_type}"
      end
    end
    actual
  end

  # Temporarily set env vars for the duration of the block and restore the
  # originals (including absence) on exit — even if the block raises.
  def self.with_env(vars_hash)
    originals = {}
    vars_hash.each do |k, v|
      originals[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    originals.each do |k, v|
      if v.nil?
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
  end

  # Normalize the raw JSON config on disk into the shape the rest of the
  # suite expects: one environment row for ENV_ID pulled out of the
  # top-level `environments` array. Matches sdk-node/setup.ts:toConfigResponse.
  def self.to_config_response(raw)
    environment = nil
    if raw['environments'].is_a?(Array)
      match = raw['environments'].find { |e| e.is_a?(Hash) && e['id'] == ENV_ID }
      environment = match if match
    end

    {
      id: raw['id'] || '',
      key: raw['key'],
      type: raw['type'],
      value_type: raw['valueType'],
      send_to_client_sdk: raw['sendToClientSdk'] || false,
      default: raw['default'] || { 'rules' => [] },
      environment: environment,
      raw: raw
    }
  end
  private_class_method :to_config_response
end
