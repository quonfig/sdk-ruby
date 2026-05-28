# frozen_string_literal: true

require 'test_helper'

class TestOptions < Minitest::Test
  API_KEY = 'abcdefg'

  def test_default_api_urls_point_to_quonfig
    # DEFAULT_API_URLS is the hardcoded fallback when neither QUONFIG_DOMAIN
    # nor an explicit api_urls: kwarg is set. Domain-derivation happens at
    # construction time, not at constant load time — see derive_api_urls.
    assert_equal [
      'https://primary.quonfig.com',
      'https://secondary.quonfig.com'
    ], Quonfig::Options::DEFAULT_API_URLS
  end

  def test_overriding_api_urls
    assert_equal Quonfig::Options::DEFAULT_API_URLS, Quonfig::Options.new.api_urls

    # a plain string ends up wrapped in an array
    api_url = 'https://example.com'
    assert_equal [api_url], Quonfig::Options.new(api_urls: api_url).api_urls

    api_urls = ['https://example.com', 'https://example2.com']
    assert_equal api_urls, Quonfig::Options.new(api_urls: api_urls).api_urls
  end

  def test_derive_stream_url_prepends_stream_to_hostname
    assert_equal 'https://stream.primary.quonfig.com',
                 Quonfig::Options.derive_stream_url('https://primary.quonfig.com')
  end

  def test_derive_stream_url_preserves_port
    assert_equal 'http://stream.localhost:6550',
                 Quonfig::Options.derive_stream_url('http://localhost:6550')
  end

  def test_derive_stream_url_preserves_scheme_and_path
    assert_equal 'http://stream.api.example.com/base',
                 Quonfig::Options.derive_stream_url('http://api.example.com/base')
  end

  def test_derive_stream_url_with_eu_subdomain
    assert_equal 'https://stream.primary.eu.quonfig.com',
                 Quonfig::Options.derive_stream_url('https://primary.eu.quonfig.com')
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

  # ---- fallback_poll_* rename (qfg-thsn) ----
  # The canonical names are `fallback_poll_enabled` and
  # `fallback_poll_interval_ms` (milliseconds). The legacy `enable_polling`
  # and `poll_interval` (seconds) kwargs / accessors are kept as deprecated
  # aliases for one minor cycle and forward transparently.

  def test_fallback_poll_enabled_defaults_true
    assert_equal true, Quonfig::Options.new.fallback_poll_enabled
    assert_equal false, Quonfig::Options.new(fallback_poll_enabled: false).fallback_poll_enabled
  end

  def test_fallback_poll_interval_ms_defaults_60_000
    assert_equal 60_000, Quonfig::Options.new.fallback_poll_interval_ms
    assert_equal 30_000,
                 Quonfig::Options.new(fallback_poll_interval_ms: 30_000).fallback_poll_interval_ms
  end

  def test_deprecated_enable_polling_kwarg_forwards_to_fallback_poll_enabled
    options = silence_deprecation_warnings { Quonfig::Options.new(enable_polling: false) }
    assert_equal false, options.fallback_poll_enabled
    assert_equal false, options.enable_polling
  end

  def test_deprecated_poll_interval_kwarg_forwards_with_unit_multiplication
    # poll_interval (seconds) must multiply *1000 into fallback_poll_interval_ms.
    options = silence_deprecation_warnings { Quonfig::Options.new(poll_interval: 30) }
    assert_equal 30_000, options.fallback_poll_interval_ms
    # The legacy accessor continues to read in seconds.
    assert_equal 30, options.poll_interval
  end

  def test_canonical_kwarg_wins_over_deprecated_alias
    options = silence_deprecation_warnings do
      Quonfig::Options.new(
        fallback_poll_enabled: true,
        enable_polling: false,
        fallback_poll_interval_ms: 5_000,
        poll_interval: 30
      )
    end
    assert_equal true, options.fallback_poll_enabled
    assert_equal 5_000, options.fallback_poll_interval_ms
  end

  # ---- init_timeout_ms rename (qfg-39za) ----
  # The canonical name is `init_timeout_ms` (milliseconds). The legacy
  # `initialization_timeout_sec` (seconds) kwarg / accessor is kept as a
  # deprecated alias for one minor cycle and forwards transparently.

  def test_init_timeout_ms_defaults_to_10_000
    assert_equal 10_000, Quonfig::Options.new.init_timeout_ms
  end

  def test_init_timeout_ms_explicit_kwarg
    assert_equal 5_000, Quonfig::Options.new(init_timeout_ms: 5_000).init_timeout_ms
  end

  def test_deprecated_initialization_timeout_sec_kwarg_forwards_with_unit_multiplication
    options = silence_deprecation_warnings { Quonfig::Options.new(initialization_timeout_sec: 2) }
    assert_equal 2_000, options.init_timeout_ms
    # The legacy accessor continues to read in seconds.
    assert_equal 2, options.initialization_timeout_sec
  end

  def test_init_timeout_canonical_kwarg_wins_over_deprecated_alias
    options = silence_deprecation_warnings do
      Quonfig::Options.new(
        init_timeout_ms: 7_500,
        initialization_timeout_sec: 30
      )
    end
    assert_equal 7_500, options.init_timeout_ms
    assert_equal 7.5, options.initialization_timeout_sec
  end

  def test_initialization_timeout_sec_default_still_10_seconds
    # Default 10_000 ms read back via legacy accessor must still be 10 (sec).
    assert_equal 10, Quonfig::Options.new.initialization_timeout_sec
  end

  def silence_deprecation_warnings
    original = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original
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

  # ---- QUONFIG_DOMAIN tests (qfg-w6gg) ----
  # A single env var `QUONFIG_DOMAIN` governs api, sse, and telemetry URL
  # derivation. Resolution order (highest wins): explicit kwargs >
  # QUONFIG_DOMAIN > hardcoded default 'quonfig.com'.

  def test_default_domain_is_quonfig_com
    with_env('QUONFIG_DOMAIN', nil) do
      options = Quonfig::Options.new
      assert_equal [
        'https://primary.quonfig.com',
        'https://secondary.quonfig.com'
      ], options.api_urls
      assert_equal 'https://telemetry.quonfig.com', options.telemetry_destination
    end
  end

  def test_quonfig_domain_env_var_derives_all_urls
    with_env('QUONFIG_DOMAIN', 'quonfig-staging.com') do
      options = Quonfig::Options.new
      assert_equal [
        'https://primary.quonfig-staging.com',
        'https://secondary.quonfig-staging.com'
      ], options.api_urls
      assert_equal [
        'https://stream.primary.quonfig-staging.com',
        'https://stream.secondary.quonfig-staging.com'
      ], options.sse_api_urls
      assert_equal 'https://telemetry.quonfig-staging.com', options.telemetry_destination
    end
  end

  def test_explicit_api_urls_override_quonfig_domain
    with_env('QUONFIG_DOMAIN', 'quonfig-staging.com') do
      options = Quonfig::Options.new(api_urls: ['http://localhost:8080'])
      assert_equal ['http://localhost:8080'], options.api_urls
    end
  end

  def test_explicit_telemetry_url_overrides_quonfig_domain
    with_env('QUONFIG_DOMAIN', 'quonfig-staging.com') do
      options = Quonfig::Options.new(telemetry_url: 'http://localhost:6555')
      assert_equal 'http://localhost:6555', options.telemetry_destination
    end
  end

  def test_quonfig_telemetry_url_env_var_no_longer_read
    # QUONFIG_TELEMETRY_URL has been removed. Setting it must not affect
    # anything; the default (quonfig.com) wins.
    with_env('QUONFIG_DOMAIN', nil) do
      with_env('QUONFIG_TELEMETRY_URL', 'https://should-be-ignored.example.com') do
        assert_equal 'https://telemetry.quonfig.com',
                     Quonfig::Options.new.telemetry_destination
      end
    end
  end
end
