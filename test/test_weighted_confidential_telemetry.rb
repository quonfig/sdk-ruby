# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'

# qfg-goi1.2.39 — a weighted-rollout variant marked confidential (or carrying
# decryptWith) must reach telemetry redacted. Resolver#get used to redact from
# the OUTER weighted_values Value, which is never flagged, so the selected
# variant's plaintext (or the decrypted secret) went out as selectedValue.
#
# Public path only: a real datadir Client, Client#get, then Client#stop drains
# telemetry to a real local capture server. The assertion is on the bytes.
class TestWeightedConfidentialTelemetry < Minitest::Test
  PLAIN_SECRET = 'plain-rollout-secret'
  DECRYPTED_SECRET = 'decrypted-rollout-secret'

  def setup
    super
    @telemetry_posts = []
    @workspace = Dir.mktmpdir('quonfig-weighted-confidential')
    FileUtils.mkdir_p(File.join(@workspace, 'configs'))
    File.write(File.join(@workspace, 'quonfig.json'), JSON.generate({ environments: ['Production'] }))

    @hex_key = Quonfig::Encryption.generate_new_hex_key
    @ciphertext = Quonfig::Encryption.new(@hex_key).encrypt(DECRYPTED_SECRET)

    write_config(plain_config('rollout.key', @hex_key))
    write_config(weighted_config('rollout.confidential',
                                 { 'type' => 'string', 'value' => PLAIN_SECRET, 'confidential' => true }))
    write_config(weighted_config('rollout.encrypted',
                                 { 'type' => 'string', 'value' => @ciphertext, 'confidential' => true,
                                   'decryptWith' => 'rollout.key' }))
    @server = start_capture_server
  end

  def teardown
    @client&.stop
    @server&.shutdown
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
    super
  end

  def test_weighted_confidential_and_decrypt_with_variants_are_redacted_on_the_wire
    @client = Quonfig::Client.new(
      sdk_key: 'qf_sk_dev_abc_deadbeef', datadir: @workspace, environment: 'Production',
      telemetry_url: "http://127.0.0.1:#{@port}", enable_sse: false, fallback_poll_enabled: false,
      collect_sync_interval: 3600
    )
    ctx = { 'user' => { 'key' => 'u1' } }
    assert_equal PLAIN_SECRET, @client.get('rollout.confidential', nil, ctx)
    assert_equal DECRYPTED_SECRET, @client.get('rollout.encrypted', nil, ctx)

    @client.stop
    @client = nil

    wire = @telemetry_posts.join
    refute_empty @telemetry_posts, 'expected a telemetry POST'
    refute_includes wire, PLAIN_SECRET, 'confidential weighted variant leaked in plaintext'
    refute_includes wire, DECRYPTED_SECRET, 'decryptWith weighted variant leaked decrypted secret'

    summaries = JSON.parse(@telemetry_posts.last)['events'].filter_map { |e| e['summaries'] }.first['summaries']
    by_key = summaries.to_h { |s| [s['key'], s['counters'][0]] }
    assert_equal({ 'string' => "*****#{Digest::MD5.hexdigest(PLAIN_SECRET)[0, 5]}" },
                 by_key['rollout.confidential']['selectedValue'])
    assert_equal({ 'string' => "*****#{Digest::MD5.hexdigest(@ciphertext)[0, 5]}" },
                 by_key['rollout.encrypted']['selectedValue'])
    assert_equal 0, by_key['rollout.encrypted']['weightedValueIndex']
  end

  private

  def write_config(cfg)
    File.write(File.join(@workspace, 'configs', "#{cfg['key']}.json"), JSON.generate(cfg))
  end

  def plain_config(key, value)
    {
      'id' => "id-#{key}", 'key' => key, 'type' => 'config', 'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                   'value' => { 'type' => 'string', 'value' => value } }] }
    }
  end

  def weighted_config(key, variant)
    {
      'id' => "id-#{key}", 'key' => key, 'type' => 'config', 'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [{
          'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
          'value' => { 'type' => 'weighted_values',
                       'value' => { 'hashByPropertyName' => 'user.key',
                                    'weightedValues' => [{ 'value' => variant, 'weight' => 100 }] } }
        }]
      }
    }
  end

  def start_capture_server
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(StringIO.new), AccessLog: [])
    server.mount_proc '/api/v1/telemetry/' do |req, res|
      @telemetry_posts << req.body
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = '{}'
    end
    @port = server.config[:Port]
    Thread.new { server.start }
    50.times do
      break if TCPSocket.new('127.0.0.1', @port).close || true
    rescue StandardError
      sleep 0.05
    end
    server
  end
end
