# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'minitest/mock'

# qf1 secrets through the public SDK surface (qfg-8seuf.11): datadir and wire
# loading, per-value failure scope, R1 (no decryptWith), telemetry
# redaction, typed getters, thread safety, no-leak and the no-X25519 build.
# Ciphertexts and keyset values come from the spec's vectors (test keys only),
# read from the sibling integration-test-data checkout.
class TestSecrets < Minitest::Test
  KEY = 'stripe.webhook.secret'
  Qf1 = Quonfig::Qf1

  def vectors
    TestQf1.vectors
  end

  def positive(name)
    vectors['positive'].find { |p| p['name'] == name } || raise("no positive vector #{name}")
  end

  def setup
    super
    @saved_keysets = ENV.to_h.select { |k, _| k.start_with?('QUONFIG_KEYSET') }
    @saved_keysets.each_key { |k| ENV.delete(k) }
    Qf1.clear_keyset_cache!
  end

  def teardown
    ENV.each_key { |k| ENV.delete(k) if k.start_with?('QUONFIG_KEYSET') }
    @saved_keysets&.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
    super
  end

  # Sets exactly +vars+ as the QUONFIG_KEYSET* environment (names with an LF
  # cannot be process env vars and are skipped: no reader may read them).
  # Others (HOME in one vector) are set for the block and restored after.
  def with_keysets(vars)
    settable = vars.reject { |k, _| k.include?("\n") }
    originals = settable.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    settable.each { |k, v| ENV[k] = v }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def secret_config(ciphertext, key: KEY, confidential: true, type: 'secret')
    value = { 'type' => 'string', 'value' => ciphertext }
    value['confidential'] = true if confidential
    {
      'id' => '', 'key' => key, 'type' => type, 'valueType' => 'string', 'sendToClientSdk' => false,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => value }] },
      'environment' => nil
    }
  end

  def plain_config(key, value, value_type: 'string')
    {
      'id' => '', 'key' => key, 'type' => 'config', 'valueType' => value_type, 'sendToClientSdk' => false,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                   'value' => { 'type' => value_type, 'value' => value } }] },
      'environment' => nil
    }
  end

  def client_for(*configs, **opts)
    store = Quonfig::ConfigStore.new
    configs.each { |c| store.set(c['key'], c) }
    Quonfig::Client.new(Quonfig::Options.new(**opts), store: store)
  end

  def write_doc(dir, doc)
    FileUtils.mkdir_p(File.join(@workspace, dir))
    File.write(File.join(@workspace, dir, "#{doc['key']}.json"), JSON.generate(doc))
  end

  def workspace_doc(key, type, value)
    {
      'key' => key, 'type' => type, 'valueType' => 'string', 'sendToClientSdk' => false,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => value }] },
      'environments' => []
    }
  end

  def make_workspace
    @workspace = Dir.mktmpdir('quonfig-qf1-secrets')
    File.write(File.join(@workspace, 'quonfig.json'), JSON.generate({ environments: ['production'] }))
  end

  def datadir_client
    Quonfig::Client.new(datadir: @workspace, environment: 'production', enable_sse: false,
                        fallback_poll_enabled: false)
  end

  # ---- datadir ---------------------------------------------------------------

  def test_datadir_loads_secrets_last_and_the_secret_shadows_a_configs_twin
    make_workspace
    p = positive('short-ascii')
    write_doc('configs', workspace_doc(KEY, 'config', { 'type' => 'string', 'value' => 'old-copy' }))
    write_doc('secrets', workspace_doc(KEY, 'secret', { 'type' => 'string', 'value' => p['ciphertext'],
                                                        'confidential' => true }))
    envelope = Quonfig::Datadir.load_envelope(@workspace, 'production')
    assert_equal KEY, envelope.configs.last['key']
    assert_equal 'secret', envelope.configs.last['type']

    with_keysets(vectors['positiveEnv']) do
      client = datadir_client
      assert_equal p['plaintext'], client.get_string(KEY)
      client.stop
    end
  end

  # The directory decides: a document in secrets/ is a secret whatever its
  # stored type says (qfg-verify guarantees "secret"; the SDK does not trust it).
  def test_datadir_directory_decides_the_secret_type
    make_workspace
    p = positive('short-ascii')
    write_doc('secrets', workspace_doc(KEY, 'config', { 'type' => 'string', 'value' => p['ciphertext'] }))
    envelope = Quonfig::Datadir.load_envelope(@workspace, 'production')
    assert_equal 'secret', envelope.configs.find { |c| c['key'] == KEY }['type']
    with_keysets(vectors['positiveEnv']) do
      client = datadir_client
      assert_equal p['plaintext'], client.get_string(KEY)
      client.stop
    end
  end

  # Spec 9.3: no keyset in the environment never fails startup; only the
  # secret's own get fails.
  def test_no_keyset_env_boots_and_fails_only_the_secret
    make_workspace
    write_doc('configs', workspace_doc('plain.value', 'config', { 'type' => 'string', 'value' => 'visible' }))
    write_doc('secrets', workspace_doc(KEY, 'secret', { 'type' => 'string', 'value' => positive('short-ascii')['ciphertext'],
                                                        'confidential' => true }))
    assert(ENV.keys.none? { |k| k.start_with?('QUONFIG_KEYSET') })
    client = datadir_client
    assert_equal 'visible', client.get_string('plain.value')
    assert_equal 'fallback', client.get_string(KEY, default: 'fallback')
    err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
    assert_match(/qf1 keyset_missing: .*QUONFIG_KEYSET_TEST/, err.message)
    assert_equal 'keyset_missing', err.qf1_code
    assert_equal 'visible', client.get_string('plain.value')
    client.stop
    assert_logged([/qf1 keyset_missing/])
  end

  # ---- wire ------------------------------------------------------------------

  def test_wire_secret_entry_decrypts
    p = positive('two-key-keyset-write-key')
    with_keysets(vectors['positiveEnv']) do
      client = client_for(secret_config(p['ciphertext']), plain_config('other', 'x'))
      assert_equal p['plaintext'], client.get_string(KEY)
      assert_equal p['plaintext'], client.get(KEY)
      assert_equal 'x', client.get_string('other')
    end
  end

  def test_wire_envelope_with_secret_type_installs_through_the_config_loader
    entry = secret_config(positive('short-ascii')['ciphertext'])
    assert_nil Quonfig::ConfigShape.problem(entry)
  end

  # ---- R1: decryptWith is never read ------------------------------------------

  def test_value_with_decrypt_with_fails_and_names_it
    cfg = plain_config('legacy.secret', 'deadbeef--cafe--f00d')
    cfg['default']['rules'][0]['value'].merge!('confidential' => true, 'decryptWith' => 'legacy.key')
    client = client_for(cfg, plain_config('legacy.key', '0' * 64))
    assert_equal 'd', client.get_string('legacy.secret', default: 'd')
    err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise('legacy.secret') }
    assert_includes err.message, 'decryptWith'
    refute_includes err.message, 'deadbeef'
    assert_logged([/decryptWith/])
  end

  def test_decrypt_with_fails_even_without_confidential
    cfg = plain_config('legacy.secret', 'ct')
    cfg['default']['rules'][0]['value']['decryptWith'] = 'legacy.key'
    client = client_for(cfg, plain_config('legacy.key', '0' * 64))
    assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise('legacy.secret') }
  end

  # ---- telemetry ---------------------------------------------------------------

  def test_secret_is_redacted_over_the_stored_string_even_without_confidential
    p = positive('short-ascii')
    store = Quonfig::ConfigStore.new(KEY => secret_config(p['ciphertext'], confidential: false))
    resolver = Quonfig::Resolver.new(store, Quonfig::Evaluator.new(store))
    with_keysets(vectors['positiveEnv']) do
      result = resolver.get(KEY, Quonfig::Context.new({}))
      assert_equal p['plaintext'], result.unwrapped_value
      assert_equal "*****#{Digest::MD5.hexdigest(p['ciphertext'])[0, 5]}", result.reportable_value
      assert_equal 'secret', result.config['type']
    end
  end

  def test_telemetry_summary_reports_type_secret_and_never_the_plaintext
    p = positive('short-ascii')
    agg = Quonfig::Telemetry::EvaluationSummariesAggregator.new(max_keys: 100)
    with_keysets(vectors['positiveEnv']) do
      client = client_for(secret_config(p['ciphertext']))
      reporter = Object.new
      reporter.define_singleton_method(:record_evaluation) { |**kw| agg.record(**kw) }
      client.instance_variable_set(:@telemetry_reporter, reporter)
      assert_equal p['plaintext'], client.get_string(KEY)
    end
    wire = JSON.generate(agg.drain_event)
    summary = JSON.parse(wire)['summaries']['summaries'].first
    assert_equal 'secret', summary['type']
    refute_includes wire, p['plaintext']
    assert_includes wire, "*****#{Digest::MD5.hexdigest(p['ciphertext'])[0, 5]}"
  end

  # ---- typed getters -------------------------------------------------------------

  # A secret is a string. Asking for another type fails like any wrong-type
  # read, and the plaintext is never echoed in the error or the log.
  def test_typed_getters_on_a_secret_never_echo_the_plaintext
    p = positive('bare-default-keyset')
    with_keysets(vectors['positiveEnv']) do
      client = client_for(secret_config(p['ciphertext']))
      %i[get_int get_float get_bool get_string_list get_duration get_json].each do |getter|
        assert_equal :dflt, client.public_send(getter, KEY, default: :dflt), getter
        err = assert_raises(Quonfig::Error, getter.to_s) { client.public_send(getter, KEY) }
        refute_includes err.message, p['plaintext'], getter
        refute_includes err.inspect, p['plaintext'], getter
        refute_includes err.full_message, p['plaintext'], getter
      end
      assert_equal p['plaintext'], client.get_string(KEY)
    end
    refute_includes $logs.string, p['plaintext']
    $logs = StringIO.new
  end

  # ---- thread safety ---------------------------------------------------------------

  def test_concurrent_first_gets_all_decrypt
    p = positive('two-key-keyset-older-key')
    q = positive('short-ascii')
    with_keysets(vectors['positiveEnv']) do
      client = client_for(secret_config(p['ciphertext']), secret_config(q['ciphertext'], key: 'other.secret'))
      20.times do
        Qf1.clear_keyset_cache!
        gate = Queue.new
        threads = Array.new(16) do |i|
          Thread.new do
            gate.pop
            i.even? ? client.get_string(KEY) : client.get_string('other.secret')
          end
        end
        16.times { gate << :go }
        results = threads.map(&:value)
        results.each_with_index { |r, i| assert_equal(i.even? ? p['plaintext'] : q['plaintext'], r) }
      end
    end
  end

  # ---- no leak ----------------------------------------------------------------------

  # Every negative vector, through the client: the error (message, inspect,
  # full_message, every cause) and the log carry no key material, no keyset
  # env value or piece of one, and not the payload.
  def test_no_failing_path_leaks_key_material_env_values_or_the_payload
    forbidden_base = ['qf1-priv-']
    vectors['keysets'].each { |ks| ks['keys'].each { |k| forbidden_base << k['privateKeyHex'] << k['privateKeyEntry'][9..] } }
    vectors['negative'].each do |n|
      payload = n['ciphertext'].split(':', -1).last.to_s
      forbidden = forbidden_base.dup
      n['env'].each_value { |v| forbidden.concat(v.split(',').map(&:strip).reject { |x| x.length < 12 }) }
      forbidden << payload if payload.length >= 12
      $logs = StringIO.new
      Qf1.clear_keyset_cache!
      with_keysets(n['env']) do
        client = client_for(secret_config(n['ciphertext']))
        err = assert_raises(Quonfig::Errors::DecryptionError, n['name']) { client.get_or_raise(KEY) }
        assert_equal 'fallback', client.get_string(KEY, default: 'fallback')
        texts = [err.message, err.inspect, err.full_message(highlight: false), $logs.string]
        cause = err.cause
        while cause
          texts << cause.message << cause.inspect
          cause = cause.cause
        end
        texts.each do |text|
          forbidden.each { |f| refute_includes text, f, "#{n['name']} leaked into: #{text[0, 200]}" }
        end
      end
    end
    $logs = StringIO.new
  end

  # ---- builds without X25519 ---------------------------------------------------------

  def test_build_without_x25519_fails_the_first_secret_get_with_a_clear_error
    p = positive('short-ascii')
    Qf1.stub(:x25519_supported?, false) do
      with_keysets(vectors['positiveEnv']) do
        client = client_for(secret_config(p['ciphertext']), plain_config('plain', 'ok'))
        assert_equal 'ok', client.get_string('plain')
        err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
        assert_includes err.message, 'qf1 unsupported_platform'
        assert_includes err.message, 'X25519'
        assert_includes err.message, 'openssl gem >= 3.0'
      end
    end
  end
end
