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
    Qf1Vectors.load
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

  # R1 for every shape: anything but absent, nil or "" fails, and no key
  # config is read (the named key config here would be found otherwise).
  def test_decrypt_with_of_any_type_fails_without_reading_a_key_config
    ['legacy.key', 1, 0, 1.5, true, false, [], ['legacy.key'], {}, { 'k' => 'v' }].each do |shape|
      cfg = plain_config('legacy.secret', 'stored-old-ciphertext')
      cfg['default']['rules'][0]['value'].merge!('confidential' => true, 'decryptWith' => shape)
      store = Quonfig::ConfigStore.new('legacy.secret' => cfg, 'legacy.key' => plain_config('legacy.key', '0' * 64))
      reads = []
      store.define_singleton_method(:get) do |key|
        reads << key
        super(key)
      end
      client = Quonfig::Client.new(Quonfig::Options.new, store: store)
      err = assert_raises(Quonfig::Errors::DecryptionError, shape.inspect) { client.get_or_raise('legacy.secret') }
      assert_includes err.message, 'decryptWith', shape.inspect
      refute_includes err.message, 'stored-old-ciphertext', shape.inspect
      assert_equal 'd', client.get_string('legacy.secret', default: 'd'), shape.inspect
      refute_includes reads, 'legacy.key', "#{shape.inspect} read the key config"
    end
    assert_logged([/decryptWith/])
  end

  def test_absent_nil_or_empty_decrypt_with_is_a_plain_value
    [nil, ''].each do |shape|
      cfg = plain_config('plain.value', 'as-stored')
      cfg['default']['rules'][0]['value']['decryptWith'] = shape
      assert_equal 'as-stored', client_for(cfg).get_string('plain.value'), shape.inspect
    end
  end

  # A provided (ENV_VAR) value carrying decryptWith fails too: R1 runs before
  # every other branch.
  def test_decrypt_with_on_a_provided_value_fails
    cfg = plain_config('legacy.provided', nil)
    cfg['default']['rules'][0]['value'] = { 'type' => 'provided', 'decryptWith' => 'legacy.key',
                                            'value' => { 'source' => 'ENV_VAR', 'lookup' => 'HOME' } }
    err = assert_raises(Quonfig::Errors::DecryptionError) { client_for(cfg).get_or_raise('legacy.provided') }
    assert_includes err.message, 'decryptWith'
  end

  # Spec 10.2 forbids decryptWith in secrets/; R1 applies there too.
  def test_decrypt_with_on_a_secret_value_fails
    cfg = secret_config(positive('short-ascii')['ciphertext'])
    cfg['default']['rules'][0]['value']['decryptWith'] = 'legacy.key'
    with_keysets(vectors['positiveEnv']) do
      err = assert_raises(Quonfig::Errors::DecryptionError) { client_for(cfg).get_or_raise(KEY) }
      assert_includes err.message, 'decryptWith'
    end
  end

  # R1 beats the secret path in datadir mode too: a secrets/ document whose
  # value carries decryptWith fails with the decryptWith error even though
  # its qf1 value would decrypt.
  def test_decrypt_with_in_a_datadir_secret_fails_before_decrypting
    make_workspace
    p = positive('short-ascii')
    write_doc('secrets', workspace_doc(KEY, 'secret', { 'type' => 'string', 'value' => p['ciphertext'],
                                                        'confidential' => true, 'decryptWith' => 'legacy.key' }))
    with_keysets(vectors['positiveEnv']) do
      client = datadir_client
      err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
      assert_includes err.message, 'decryptWith'
      assert_nil err.qf1_code
      client.stop
    end
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

  # Known plaintext on the invalid-UTF-8 path: a sentinel sealed in front of
  # invalid bytes (key minted at run time) appears nowhere in the error, its
  # causes, its backtrace or the log.
  def test_invalid_utf8_plaintext_never_leaks_its_valid_prefix
    sentinel = 'SENTINEL-7f3a9c-do-not-leak'
    keyset = 'QUONFIG_KEYSET_SENTINEL_TEST'
    ciphertext = Qf1TestSecret.seal(keyset, 'sentinel', "#{sentinel}\xff\xfe\xc0\x80".b)
    $logs = StringIO.new
    with_keysets(keyset => Qf1TestSecret.private_entry('sentinel')) do
      client = client_for(secret_config(ciphertext))
      err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
      assert_equal 'decrypt_failed', err.qf1_code
      assert_equal 'd', client.get_string(KEY, default: 'd')
      texts = [err.message, err.inspect, err.full_message(highlight: false), Array(err.backtrace).join("\n"),
               $logs.string]
      cause = err.cause
      while cause
        texts << cause.message << cause.inspect << cause.full_message(highlight: false) << Array(cause.backtrace).join("\n")
        cause = cause.cause
      end
      texts.each { |t| refute_includes t.b, sentinel.b }
      refute_includes $logs.string.b, sentinel[0, 8].b
    end
    $logs = StringIO.new
  end

  # Authentication-failure path: none of the derived intermediates (shared
  # secret, PRK, OKM, AES key, nonce) appear anywhere, in hex or base64.
  def test_tampered_tag_never_leaks_derived_intermediates
    n = vectors['negative'].find { |x| x['name'] == 'tampered-tag-byte' }
    parsed = Qf1.parse(n['ciphertext'])
    held = Qf1.parse_keyset_env(parsed.keyset, n['env'][parsed.keyset])[parsed.fingerprint]
    shared = Qf1.x25519(held.private_key, parsed.ephemeral_public_key)
    d = Qf1.derive(shared, parsed.ephemeral_public_key, held.public_key)
    secrets = [shared, d[:prk], d[:okm], d[:key], d[:nonce], held.private_key]
    forms = secrets.flat_map do |bytes|
      [bytes.unpack1('H*'), bytes.unpack1('H*').upcase, [bytes].pack('m0'), Qf1.encode_base64url(bytes),
       [bytes].pack('m0').delete('=')]
    end
    $logs = StringIO.new
    with_keysets(n['env']) do
      client = client_for(secret_config(n['ciphertext']))
      err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
      assert_equal 'decrypt_failed', err.qf1_code
      assert_equal 'd', client.get_string(KEY, default: 'd')
      texts = [err.message, err.inspect, err.full_message(highlight: false), Array(err.backtrace).join("\n"),
               $logs.string]
      cause = err.cause
      while cause
        texts << cause.message << cause.inspect << cause.full_message(highlight: false) << Array(cause.backtrace).join("\n")
        cause = cause.cause
      end
      texts.each { |t| forms.each { |f| refute_includes t, f } }
    end
    $logs = StringIO.new
  end

  # The decrypted value keeps its confidential flag where the SDK exposes the
  # value hash (Resolver results), and the details report the secret type.
  def test_decrypted_value_keeps_its_confidential_flag
    p = positive('short-ascii')
    with_keysets(vectors['positiveEnv']) do
      client = client_for(secret_config(p['ciphertext']))
      result = client.resolver.get(KEY, Quonfig::Context.new({}))
      assert_equal true, result.value['confidential']
      assert_equal p['plaintext'], result.value['value']
      details = client.get_string_details(KEY)
      assert_equal p['plaintext'], details.value
      assert_equal 'secret', details.flag_metadata['config_type']
    end
  end

  # Junk in secrets/ never stops startup: each bad entry is skipped with one
  # warning naming the path only, never its content. (configs/ on main
  # raises for a non-JSON *.json file or one with no key; unchanged.)
  def test_junk_in_secrets_dir_is_skipped_with_a_path_only_warning
    make_workspace
    write_doc('configs', workspace_doc('plain.value', 'config', { 'type' => 'string', 'value' => 'visible' }))
    write_doc('secrets', workspace_doc(KEY, 'secret', { 'type' => 'string', 'value' => positive('short-ascii')['ciphertext'],
                                                        'confidential' => true }))
    dir = File.join(@workspace, 'secrets')
    File.write(File.join(dir, 'broken.json'), "{ not json JUNKCONTENT-1 qf1-priv-#{'Q' * 43}")
    File.write(File.join(dir, 'nokey.json'), JSON.generate({ 'value' => 'JUNKCONTENT-2' }))
    File.write(File.join(dir, 'array.json'), JSON.generate(['JUNKCONTENT-3']))
    File.write(File.join(dir, 'README.txt'), 'JUNKCONTENT-4')
    FileUtils.mkdir_p(File.join(dir, 'nested'))
    FileUtils.mkdir_p(File.join(dir, 'dir.json'))
    warns = []
    with_keysets(vectors['positiveEnv']) do
      Quonfig::Datadir::LOG.stub(:warn, ->(msg = nil, &_) { warns << msg.to_s }) do
        client = datadir_client
        assert_equal 'visible', client.get_string('plain.value')
        assert_equal positive('short-ascii')['plaintext'], client.get_string(KEY)
        client.stop
      end
    end
    log = warns.join("\n") + $logs.string
    %w[broken.json nokey.json array.json dir.json].each do |f|
      assert_equal 1, log.lines.grep(/skipping .*#{Regexp.escape(f)}/).size, "#{f}: #{log}"
    end
    refute_match(/JUNKCONTENT|qf1-priv-/, log)
    refute_match(/README\.txt|nested/, log)
    $logs = StringIO.new
  end

  # A runtime whose OpenSSL refuses X25519 (FIPS) fails per value with a
  # message naming the restriction, never blaming the key entry.
  def test_openssl_refusing_x25519_fails_per_value_naming_the_runtime
    p = positive('short-ascii')
    refuse = ->(*) { raise OpenSSL::PKey::PKeyError, 'unsupported algorithm (FIPS)' }
    with_keysets(vectors['positiveEnv']) do
      client = client_for(secret_config(p['ciphertext']), plain_config('plain', 'ok'))
      saved = Qf1.instance_variable_get(:@supported)
      [true, nil].each do |probe|
        Qf1.instance_variable_set(:@supported, probe)
        Qf1.clear_keyset_cache!
        OpenSSL::PKey.stub(:read, refuse) do
          assert_equal 'ok', client.get_string('plain')
          err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
          assert_equal 'unsupported_platform', err.qf1_code, probe.inspect
          assert_match(/FIPS/, err.message)
          refute_match(/entry \d|not a qf1 private key|keyset_invalid/, err.message)
          assert_equal 'd', client.get_string(KEY, default: 'd')
        end
      end
    ensure
      Qf1.instance_variable_set(:@supported, saved)
    end
    $logs = StringIO.new
  end

  # The keyset cache hits: once a keyset is parsed, a read does exactly one
  # X25519 (the ECDH); a first read also derives each held public key.
  # Plaintext is never cached. Changing, emptying, removing and restoring the
  # env var takes effect on the next read.
  def test_keyset_cache_hits_and_follows_the_env
    p = positive('two-key-keyset-write-key')
    keyset = p['keyset']
    good = vectors['positiveEnv'][keyset]
    calls = 0
    original = Qf1.method(:x25519)
    counting = lambda do |*args|
      calls += 1
      original.call(*args)
    end
    client = client_for(secret_config(p['ciphertext']))
    Qf1.stub(:x25519, counting) do
      with_keysets(keyset => good) do
        assert_equal p['plaintext'], client.get_string(KEY)
        assert_equal 3, calls, 'first read: two public keys + one ECDH'
        calls = 0
        assert_equal p['plaintext'], client.get_string(KEY)
        assert_equal 1, calls, 'second read: the ECDH only (keyset cached)'

        ENV[keyset] = vectors['positiveEnv']['QUONFIG_KEYSET']
        err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
        assert_equal 'key_not_held', err.qf1_code
        ENV[keyset] = ''
        err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
        assert_equal 'keyset_missing', err.qf1_code
        ENV.delete(keyset)
        err = assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
        assert_equal 'keyset_missing', err.qf1_code
        ENV[keyset] = good
        assert_equal p['plaintext'], client.get_string(KEY)
      end
    end
  end

  # Writer-chosen keyset names cannot grow the cache without bound, and a
  # name whose env var is unset is never cached.
  def test_keyset_cache_is_bounded_and_skips_unset_names
    entry = Qf1TestSecret.private_entry('bounded')
    200.times { |i| Qf1.keyset("QUONFIG_KEYSET_B#{i}", entry) }
    assert_operator Qf1.keyset_cache_size, :<=, Qf1::KEYSET_CACHE_MAX
    Qf1.clear_keyset_cache!
    assert_raises(Qf1::Error) { Qf1.keyset('QUONFIG_KEYSET_UNSET', nil) }
    assert_equal 0, Qf1.keyset_cache_size
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
