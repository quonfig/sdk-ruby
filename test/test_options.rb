# frozen_string_literal: true

require 'test_helper'

class TestOptions < Minitest::Test
  API_KEY = 'abcdefg'

  def test_api_override_env_var
    assert_equal Quonfig::Options::DEFAULT_SOURCES, Quonfig::Options.new.sources

    # blank doesn't take effect
    with_env('QUONFIG_SOURCES', '') do
      assert_equal Quonfig::Options::DEFAULT_SOURCES, Quonfig::Options.new.sources
    end

    # non-blank does take effect
    with_env('QUONFIG_SOURCES', 'https://override.example.com') do
      assert_equal ["https://override.example.com"], Quonfig::Options.new.sources
    end
  end

  def test_default_sources_point_to_quonfig
    assert_equal [
      'https://primary.quonfig.com',
      'https://secondary.quonfig.com',
    ], Quonfig::Options::DEFAULT_SOURCES
  end

  def test_overriding_sources
    assert_equal Quonfig::Options::DEFAULT_SOURCES, Quonfig::Options.new.sources

    # a plain string ends up wrapped in an array
    source = 'https://example.com'
    assert_equal [source], Quonfig::Options.new(sources: source).sources

    sources = ['https://example.com', 'https://example2.com']
    assert_equal sources, Quonfig::Options.new(sources: sources).sources
  end

  def test_works_with_named_arguments
    assert_equal API_KEY, Quonfig::Options.new(sdk_key: API_KEY).sdk_key
  end

  def test_works_with_hash
    assert_equal API_KEY, Quonfig::Options.new({ sdk_key: API_KEY }).sdk_key
  end

  def test_sdk_key_reads_from_quonfig_backend_sdk_key
    with_env('QUONFIG_BACKEND_SDK_KEY', 'env-key') do
      assert_equal 'env-key', Quonfig::Options.new.sdk_key
    end
  end

  def test_environment_reads_from_quonfig_environment
    with_env('QUONFIG_ENVIRONMENT', 'staging') do
      assert_equal 'staging', Quonfig::Options.new.environment
    end
  end

  def test_environment_explicit_overrides_env_var
    with_env('QUONFIG_ENVIRONMENT', 'staging') do
      assert_equal 'production', Quonfig::Options.new(environment: 'production').environment
    end
  end

  def test_enable_sse_defaults_true
    assert_equal true, Quonfig::Options.new.enable_sse
    assert_equal false, Quonfig::Options.new(enable_sse: false).enable_sse
  end

  def test_enable_polling_defaults_true
    assert_equal true, Quonfig::Options.new.enable_polling
    assert_equal false, Quonfig::Options.new(enable_polling: false).enable_polling
  end

  def test_datadir_reads_from_quonfig_dir_env
    with_env('QUONFIG_DIR', '/tmp/some/workspace') do
      assert_equal '/tmp/some/workspace', Quonfig::Options.new.datadir
    end
  end

  def test_datadir_explicit_overrides_env_var
    with_env('QUONFIG_DIR', '/tmp/env/workspace') do
      assert_equal '/tmp/explicit', Quonfig::Options.new(datadir: '/tmp/explicit').datadir
    end
  end

  def test_datadir_predicate
    assert_equal false, Quonfig::Options.new.datadir?
    assert_equal true, Quonfig::Options.new(datadir: '/tmp/ws').datadir?
  end

  def test_local_only_uses_datadir_presence
    refute Quonfig::Options.new.local_only?
    assert Quonfig::Options.new(datadir: '/tmp/ws').local_only?
  end

  def test_collect_max_paths
    assert_equal 1000, Quonfig::Options.new.collect_max_paths
    assert_equal 100, Quonfig::Options.new(collect_max_paths: 100).collect_max_paths
  end

  def test_collect_max_evaluation_summaries
    assert_equal 100_000, Quonfig::Options.new.collect_max_evaluation_summaries
    assert_equal 0, Quonfig::Options.new(collect_evaluation_summaries: false).collect_max_evaluation_summaries
    assert_equal 3,
                 Quonfig::Options.new(collect_max_evaluation_summaries: 3).collect_max_evaluation_summaries
  end

  def test_context_upload_mode_periodic
    options = Quonfig::Options.new(context_upload_mode: :periodic_example, context_max_size: 100)
    assert_equal 100, options.collect_max_example_contexts

    options = Quonfig::Options.new(context_upload_mode: :none)
    assert_equal 0, options.collect_max_example_contexts
  end

  def test_context_upload_mode_shapes_only
    options = Quonfig::Options.new(context_upload_mode: :shapes_only, context_max_size: 100)
    assert_equal 100, options.collect_max_shapes

    options = Quonfig::Options.new(context_upload_mode: :none)
    assert_equal 0, options.collect_max_shapes
  end

  def test_context_upload_mode_none
    options = Quonfig::Options.new(context_upload_mode: :none)
    assert_equal 0, options.collect_max_example_contexts

    options = Quonfig::Options.new(context_upload_mode: :none)
    assert_equal 0, options.collect_max_shapes
  end

  def test_telemetry_destination_reads_env_first
    with_env('QUONFIG_TELEMETRY_URL', 'https://custom-telemetry.example.com') do
      assert_equal 'https://custom-telemetry.example.com', Quonfig::Options.new.telemetry_destination
    end
  end

  def test_telemetry_destination_derives_from_default_sources
    assert_equal 'https://telemetry.quonfig.com', Quonfig::Options.new.telemetry_destination
  end

  def test_telemetry_destination_derives_from_custom_quonfig_sources
    options = Quonfig::Options.new(sources: ['https://primary.eu.quonfig.com'])
    assert_equal 'https://telemetry.eu.quonfig.com', options.telemetry_destination
  end
end
