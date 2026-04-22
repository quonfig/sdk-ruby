# frozen_string_literal: true

require 'test_helper'
require 'ostruct'
require 'json'

class TestConfigLoader < Minitest::Test
  def setup
    super
    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key',
      api_urls: ['https://primary.example.test']
    )
    @loader = Quonfig::ConfigLoader.new(MockBaseClient.new(options))
  end

  def test_fetch_200_populates_configs_and_stores_etag_then_304_is_a_noop
    body = JSON.generate(
      'configs' => [
        { 'key' => 'my.flag', 'type' => 'config', 'valueType' => 'bool',
          'default' => { 'rules' => [] } }
      ],
      'meta' => { 'version' => 'v1', 'environment' => 'production' }
    )
    ok_response = Faraday::Response.new(
      status: 200, body: body,
      response_headers: { 'ETag' => 'W/"etag-one"' }
    )
    not_modified = Faraday::Response.new(
      status: 304, body: '', response_headers: {}
    )

    observed_headers = []

    http_conn = Minitest::Mock.new
    http_conn.expect(:get, ok_response) do |path, headers|
      observed_headers << headers.dup
      path == '/api/v2/configs' && !headers.key?('If-None-Match')
    end
    http_conn.expect(:get, not_modified) do |path, headers|
      observed_headers << headers.dup
      path == '/api/v2/configs' && headers['If-None-Match'] == 'W/"etag-one"'
    end

    Quonfig::HttpConnection.stub :new, ->(_uri, _key) { http_conn } do
      assert_equal :updated, @loader.fetch!
      assert_equal :not_modified, @loader.fetch!
    end

    assert_equal 'W/"etag-one"', @loader.etag
    calc = @loader.calc_config
    assert calc.key?('my.flag'), "expected 'my.flag' to be loaded"
    assert_equal 'W/"etag-one"', observed_headers[1]['If-None-Match']
    http_conn.verify
  end

  def test_set_and_rm_preserved
    config = OpenStruct.new(key: 'x', rows: [1])
    @loader.set(config, :test)
    assert @loader.calc_config.key?('x')

    @loader.rm('x')
    refute @loader.calc_config.key?('x')
  end

  def test_no_highwater_mark_attribute
    refute @loader.respond_to?(:highwater_mark),
           'highwater_mark should be removed from ConfigLoader'
  end
end
