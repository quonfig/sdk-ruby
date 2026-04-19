# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

# qfg-dk6.18 — Quonfig::Datadir loads JSON config files from a workspace
# directory and produces a ConfigEnvelope (and a populated ConfigStore) for
# offline / datadir mode. Mirrors sdk-node/src/datadir.ts.
class TestDatadir < Minitest::Test
  CONFIG_SUBDIRS = %w[configs feature-flags segments schemas log-levels].freeze

  def setup
    @tmpdir = Dir.mktmpdir('quonfig-datadir-test')
    CONFIG_SUBDIRS.each { |sub| FileUtils.mkdir_p(File.join(@tmpdir, sub)) }
    File.write(File.join(@tmpdir, 'quonfig.json'), JSON.generate({ environments: %w[Production Staging] }))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    ENV.delete('QUONFIG_ENVIRONMENT')
  end

  def write_config(subdir, filename, body)
    File.write(File.join(@tmpdir, subdir, filename), JSON.generate(body))
  end

  def sample_config(key, environment_id: 'Production')
    {
      'id' => '111',
      'key' => key,
      'type' => 'config',
      'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'string', 'value' => 'hello' } }] },
      'environments' => [{ 'id' => environment_id, 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'string', 'value' => 'env-hello' } }] }]
    }
  end

  def sample_flag(key)
    {
      'id' => '222',
      'key' => key,
      'type' => 'feature_flag',
      'valueType' => 'bool',
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'bool', 'value' => false } }] },
      'environments' => []
    }
  end

  def test_load_envelope_returns_config_envelope
    write_config('configs', 'a.config.json', sample_config('a.config'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    assert_instance_of Quonfig::ConfigEnvelope, envelope
  end

  def test_load_envelope_reads_configs_from_each_subdir
    write_config('configs', 'a.config.json', sample_config('a.config'))
    write_config('feature-flags', 'b.flag.json', sample_flag('b.flag'))
    write_config('log-levels', 'c.log.json', sample_config('c.log'))
    write_config('segments', 'd.segment.json', sample_config('d.segment'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    keys = envelope.configs.map { |c| c['key'] }
    assert_equal %w[a.config c.log d.segment b.flag].sort, keys.sort
  end

  def test_load_envelope_skips_non_json_and_missing_subdirs
    write_config('configs', 'a.config.json', sample_config('a.config'))
    File.write(File.join(@tmpdir, 'configs', 'README.md'), '# ignore me')
    FileUtils.rm_rf(File.join(@tmpdir, 'segments'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    keys = envelope.configs.map { |c| c['key'] }
    assert_equal ['a.config'], keys
  end

  def test_load_envelope_picks_environment_block_by_id
    write_config('configs', 'a.config.json', sample_config('a.config', environment_id: 'Production'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    cfg = envelope.configs.first
    refute_nil cfg['environment'], 'expected environment field to be populated'
    assert_equal 'Production', cfg['environment']['id']
  end

  def test_load_envelope_environment_field_nil_when_no_match
    write_config('configs', 'a.config.json', sample_config('a.config', environment_id: 'Other'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    cfg = envelope.configs.first
    assert_nil cfg['environment']
  end

  def test_load_envelope_send_to_client_sdk_true_for_feature_flag
    write_config('feature-flags', 'b.flag.json', sample_flag('b.flag'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    cfg = envelope.configs.first
    assert_equal true, cfg['sendToClientSdk'], 'feature_flag must always sendToClientSdk=true'
  end

  def test_load_envelope_default_rules_when_missing
    raw = sample_config('a.config')
    raw.delete('default')
    write_config('configs', 'a.config.json', raw)

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    cfg = envelope.configs.first
    assert_equal({ 'rules' => [] }, cfg['default'])
  end

  def test_load_envelope_meta_includes_version_and_environment
    write_config('configs', 'a.config.json', sample_config('a.config'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    assert_equal "datadir:#{@tmpdir}", envelope.meta['version']
    assert_equal 'Production', envelope.meta['environment']
  end

  def test_resolve_environment_from_env_var
    write_config('configs', 'a.config.json', sample_config('a.config'))
    ENV['QUONFIG_ENVIRONMENT'] = 'Production'

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, nil)

    assert_equal 'Production', envelope.meta['environment']
  end

  def test_constructor_environment_supersedes_env_var
    write_config('configs', 'a.config.json', sample_config('a.config'))
    ENV['QUONFIG_ENVIRONMENT'] = 'Staging'

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'Production')

    assert_equal 'Production', envelope.meta['environment']
  end

  def test_raises_when_no_environment
    err = assert_raises(ArgumentError) { Quonfig::Datadir.load_envelope(@tmpdir, nil) }
    assert_match(/Environment required for datadir mode/, err.message)
  end

  def test_raises_when_quonfig_json_missing
    File.delete(File.join(@tmpdir, 'quonfig.json'))

    err = assert_raises(ArgumentError) { Quonfig::Datadir.load_envelope(@tmpdir, 'Production') }
    assert_match(/missing quonfig\.json/, err.message)
  end

  def test_raises_when_environment_not_in_workspace
    err = assert_raises(ArgumentError) { Quonfig::Datadir.load_envelope(@tmpdir, 'NotAnEnv') }
    assert_match(/Environment "NotAnEnv" not found/, err.message)
    assert_match(/Production/, err.message)
  end

  def test_allows_any_environment_when_quonfig_json_environments_empty
    File.write(File.join(@tmpdir, 'quonfig.json'), JSON.generate({ environments: [] }))
    write_config('configs', 'a.config.json', sample_config('a.config'))

    envelope = Quonfig::Datadir.load_envelope(@tmpdir, 'AnythingGoes')

    assert_equal 'AnythingGoes', envelope.meta['environment']
  end

  def test_load_store_returns_populated_config_store
    write_config('configs', 'a.config.json', sample_config('a.config'))
    write_config('feature-flags', 'b.flag.json', sample_flag('b.flag'))

    store = Quonfig::Datadir.load_store(@tmpdir, 'Production')

    assert_instance_of Quonfig::ConfigStore, store
    assert_equal %w[a.config b.flag].sort, store.keys.sort
    assert_equal 'a.config', store.get('a.config')['key']
  end

  # Verification against the real integration-test-data fixture (path-based).
  # Skips when the sibling repo is not present (e.g. limited CI checkouts).
  def test_load_store_with_integration_test_data_fixture
    fixture = File.expand_path('../../integration-test-data/data/integration-tests', __dir__)
    skip "integration-test-data not present at #{fixture}" unless Dir.exist?(fixture)

    store = Quonfig::Datadir.load_store(fixture, 'Production')

    refute_empty store.keys, 'expected at least one config key from integration-test-data'
    assert(store.keys.any? { |k| k.start_with?('a.') } || store.keys.include?('already.in.use'),
           "expected to find familiar fixture keys; got: #{store.keys.first(5).inspect}")
  end
end
