# frozen_string_literal: true

require 'test_helper'

class TestConfigClient < Minitest::Test
  def setup
    super
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      x_use_local_cache: true,
    )

    @config_client = Quonfig::ConfigClient.new(MockBaseClient.new(options), 10)
  end


  def test_initialization_timeout_error
    options = Quonfig::Options.new(
      sdk_key: '123-ENV-KEY-SDK',
      initialization_timeout_sec: 0.01
    )

    err = assert_raises(Quonfig::Errors::InitializationTimeoutError) do
      Quonfig::Client.new(options).config_client.get('anything')
    end

    assert_match(/couldn't initialize in 0.01 second timeout/, err.message)
  end


  def test_invalid_api_key_error
    options = Quonfig::Options.new(
      sdk_key: ''
    )

    err = assert_raises(Quonfig::Errors::InvalidSdkKeyError) do
      Quonfig::Client.new(options).config_client.get('anything')
    end

    assert_match(/No SDK key/, err.message)

    options = Quonfig::Options.new(
      sdk_key: 'invalid'
    )

    err = assert_raises(Quonfig::Errors::InvalidSdkKeyError) do
      Quonfig::Client.new(options).config_client.get('anything')
    end

    assert_match(/format is invalid/, err.message)
  end

  def test_caching
    @config_client.send(:cache_configs,
                        PrefabProto::Configs.new(configs:
                                                   [PrefabProto::Config.new(key: 'test', id: 1,
                                                                            rows: [PrefabProto::ConfigRow.new(
                                                                              values: [
                                                                                PrefabProto::ConditionalValue.new(
                                                                                  value: PrefabProto::ConfigValue.new(string: "test value")
                                                                                )
                                                                              ]
                                                                            )])],
                                                 config_service_pointer: PrefabProto::ConfigServicePointer.new(project_id: 3, project_env_id: 5)))
    @config_client.send(:load_cache)
    assert_equal "test value", @config_client.get("test")
  end

  def test_cache_path_respects_xdg
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      x_use_local_cache: true,
      sdk_key: "123-ENV-KEY-SDK",)

    config_client = Quonfig::ConfigClient.new(MockBaseClient.new(options), 10)
    assert_equal "#{Dir.home}/.cache/prefab.cache.123.json", config_client.send(:cache_path)

    with_env('XDG_CACHE_HOME', '/tmp') do
      config_client = Quonfig::ConfigClient.new(MockBaseClient.new(options), 10)
      assert_equal "/tmp/prefab.cache.123.json", config_client.send(:cache_path)
    end
  end

  def test_load_url_with_empty_body
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      x_use_local_cache: true,
      sdk_key: "123-ENV-KEY-SDK",)

    config_client = Quonfig::ConfigClient.new(MockBaseClient.new(options), 10)

    # Mock connection with empty response body
    mock_conn = Minitest::Mock.new
    mock_resp = Minitest::Mock.new
    mock_resp.expect(:status, 200)
    mock_resp.expect(:body, '')
    mock_resp.expect(:body, '')
    mock_conn.expect(:get, mock_resp, [''])
    mock_conn.expect(:uri, 'http://test.example.com')

    result = config_client.send(:load_url, mock_conn, :test_source)

    assert_equal false, result, 'Expected load_url to return false for empty body'
    mock_conn.verify
    mock_resp.verify

    assert_logged [/Response body is empty/]
  end

  def test_load_cache_with_empty_file
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      x_use_local_cache: true,
      sdk_key: "123-ENV-KEY-SDK",)

    config_client = Quonfig::ConfigClient.new(MockBaseClient.new(options), 10)
    cache_path = config_client.send(:cache_path)

    # Create an empty cache file
    FileUtils.mkdir_p(File.dirname(cache_path))
    File.write(cache_path, '')

    result = config_client.send(:load_cache)

    assert_equal false, result, 'Expected load_cache to return false for empty file'
    assert_logged [/File is empty/]
  ensure
    File.delete(cache_path) if File.exist?(cache_path)
  end

  def test_load_json_file_with_empty_file
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      x_use_local_cache: true,
      sdk_key: "123-ENV-KEY-SDK",)

    config_client = Quonfig::ConfigClient.new(MockBaseClient.new(options), 10)

    # Create a temporary empty datafile
    temp_file = File.join(Dir.tmpdir, 'test_empty_datafile.json')
    File.write(temp_file, '')

    result = config_client.send(:load_json_file, temp_file)

    assert_equal false, result, 'Expected load_json_file to return false for empty file'
    assert_logged [/File is empty/]
  ensure
    File.delete(temp_file) if File.exist?(temp_file)
  end

end
