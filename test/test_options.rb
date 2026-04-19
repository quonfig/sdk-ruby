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

  def test_collect_max_paths
    assert_equal 1000, Quonfig::Options.new.collect_max_paths
    assert_equal 100, Quonfig::Options.new(collect_max_paths: 100).collect_max_paths
  end

  def test_collect_max_paths_with_local_only
    options = Quonfig::Options.new(collect_max_paths: 100,
                                  prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY)
    assert_equal 0, options.collect_max_paths
  end

  def test_collect_max_paths_with_collect_logger_counts_false
    options = Quonfig::Options.new(collect_max_paths: 100,
                                  collect_logger_counts: false)
    assert_equal 0, options.collect_max_paths
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

  def test_context_upload_mode_shape_only
    options = Quonfig::Options.new(context_upload_mode: :shape_only, context_max_size: 100)
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

  def test_loading_a_datafile
    options = Quonfig::Options.new(datafile: "#{Dir.pwd}/test/fixtures/datafile.json")
    assert_equal "#{Dir.pwd}/test/fixtures/datafile.json", options.datafile
  end
end
