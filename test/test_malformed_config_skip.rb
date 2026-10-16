# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

# qfg-krjt (audit 2026-10-16 M3; WS8 skip-one-bad-config rule, sdk-go 2f6b98b,
# sdk-node qfg-goi1.10.1, sdk-python qfg-goi1.10.5). A config whose rule,
# criterion or default has the wrong shape, or whose weighted value carries a
# non-integer weight, used to install and then raise NoMethodError/TypeError
# out of get/enabled? on every read. It is now skipped at decode with a WARN
# naming its key (the key reads as not found), and the rest installs. If every
# config fails, the payload is still rejected.
class TestMalformedConfigSkip < Minitest::Test
  PRIMARY = 'https://primary.example.test'

  class FakeConn
    def initialize(responses)
      @responses = responses
    end

    def get(_path, _headers)
      status, body = @responses.length > 1 ? @responses.shift : @responses.first
      Faraday::Response.new(status: status, body: body, response_headers: {})
    end
  end

  def bool_rule(val, criteria = [{ 'operator' => 'ALWAYS_TRUE' }])
    { 'criteria' => criteria, 'value' => { 'type' => 'bool', 'value' => val } }
  end

  def flag(key, default)
    { 'id' => "id-#{key}", 'key' => key, 'type' => 'feature_flag', 'valueType' => 'bool', 'default' => default }
  end

  def good
    flag('good.flag', { 'rules' => [bool_rule(true)] })
  end

  def bad_configs
    [
      flag('bad.rules', { 'rules' => ['oops'] }),
      flag('bad.criteria', { 'rules' => [{ 'criteria' => 'oops', 'value' => { 'type' => 'bool', 'value' => true } }] }),
      flag('bad.default', 'oops'),
      flag('bad.weights', { 'rules' => [{
             'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
             'value' => { 'type' => 'weighted_values',
                          'value' => { 'hashByPropertyName' => 'user.key',
                                       'weightedValues' => [
                                         { 'weight' => 'abc', 'value' => { 'type' => 'bool', 'value' => true } }
                                       ] } }
           }] })
    ]
  end

  BAD_KEYS = %w[bad.rules bad.criteria bad.default bad.weights].freeze

  def body(configs, gen)
    JSON.generate('configs' => configs,
                  'meta' => { 'version' => "v#{gen}", 'environment' => 'production', 'generation' => gen })
  end

  def build
    options = Quonfig::Options.new(sdk_key: '1-test-sdk-key', api_urls: [PRIMARY],
                                   enable_sse: false, fallback_poll_enabled: false)
    @store = Quonfig::ConfigStore.new
    @loader = Quonfig::ConfigLoader.new(@store, options)
    @client = Quonfig::Client.new(store: @store)
  end

  def fetch_with(responses, &block)
    conn = FakeConn.new(responses)
    Quonfig::HttpConnection.stub(:new, ->(*_args, **_kw) { conn }, &block)
  end

  def assert_bad_keys_read_as_missing
    assert @client.enabled?('good.flag'), 'the good config in the same payload must install'
    BAD_KEYS.each do |key|
      refute @client.enabled?(key, context: { user: { key: 'u1' } }), "#{key} must read as not found"
      assert_equal 'fallback', @client.get(key, 'fallback'), "#{key} must return the caller's default"
    end
  end

  def test_http_payload_skips_malformed_configs_and_installs_the_rest
    build
    fetch_with([[200, body([good] + bad_configs, 3)]]) do
      assert_equal :updated, @loader.fetch!
    end
    assert_bad_keys_read_as_missing
    assert_logged(BAD_KEYS.map { |k| /skipping config "#{Regexp.escape(k)}"/ })
  ensure
    @client&.stop
  end

  def test_http_payload_where_every_config_is_malformed_is_rejected
    build
    fetch_with([[200, body([good], 3)], [200, body(bad_configs, 4)]]) do
      assert_equal :updated, @loader.fetch!
      assert_equal :failed, @loader.fetch!, 'an all-bad payload is a leg error'
    end
    assert_equal %w[good.flag], @store.keys, 'the previous configs must stay'
    assert_equal 3, @loader.held_generation
    assert_logged([/skipping config "bad.rules"/, /every config failed to load/])
  ensure
    @client&.stop
  end

  def test_sse_event_skips_malformed_configs
    events = []
    parser = Quonfig::SSEConfigClient::EventParser.new
    parser.feed("data: #{body([good] + bad_configs, 5)}\n\n") { |ev| events << ev }
    assert_equal 1, events.size
    assert_equal(%w[good.flag], events.first.envelope.configs.map { |c| c['key'] })
    assert_logged([/skipping config "bad.weights"/])
  end

  def test_sse_event_where_every_config_is_malformed_is_dropped
    events = []
    parser = Quonfig::SSEConfigClient::EventParser.new
    parser.feed("data: #{body(bad_configs, 5)}\n\n") { |ev| events << ev }
    assert_empty events
    assert_logged([/every config failed to load/])
  end

  def test_datadir_skips_a_malformed_config_file
    Dir.mktmpdir('quonfig-malformed') do |dir|
      File.write(File.join(dir, 'quonfig.json'), JSON.generate('environments' => ['production']))
      FileUtils.mkdir_p(File.join(dir, 'feature-flags'))
      File.write(File.join(dir, 'feature-flags', 'good.flag.json'), JSON.generate(good))
      bad = flag('bad.rules', { 'rules' => ['oops'] })
      File.write(File.join(dir, 'feature-flags', 'bad.rules.json'), JSON.generate(bad))

      client = Quonfig::Client.new(datadir: dir, environment: 'production', enable_sse: false,
                                   enable_polling: false, collect_evaluation_summaries: false,
                                   context_upload_mode: :none)
      begin
        assert client.enabled?('good.flag')
        refute client.enabled?('bad.rules')
        assert_equal 'fallback', client.get('bad.rules', 'fallback')
      ensure
        client.stop
      end
    end
    assert_logged([/skipping config "bad.rules"/])
  end
end
