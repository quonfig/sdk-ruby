# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'openssl'

# qf1 reader known-answer tests (qfg-8seuf.11), driven by the spec's vectors
# file (project/plans/secrets-qf1-spec.md section 14) as integration-test-data
# carries it. The file is read from the sibling checkout CI uses; no key
# material is copied into this repo.
#
# Every reader-relevant group is driven: rfcChecks, positive[] (decrypt and
# every intermediate), decryptOnly[], negative[] (exact class, each with its
# own env, any variable not listed unset), privateKeyEntry and envValue
# keyEntryCases[]. publicKeyEntry cases and writerCases[] are writer/verify
# rules this SDK does not implement (it never encrypts).
class TestQf1 < Minitest::Test
  VECTORS_PATH = File.expand_path('../../integration-test-data/tests/secrets/qf1-vectors.json', __dir__)
  Qf1 = Quonfig::Qf1

  def self.vectors
    @vectors ||= begin
      unless File.exist?(VECTORS_PATH)
        raise "[qf1 tests] vectors not found at #{VECTORS_PATH}: clone quonfig/integration-test-data " \
              'as a sibling of sdk-ruby (CI checks it out there).'
      end

      JSON.parse(File.read(VECTORS_PATH, encoding: 'UTF-8'))
    end
  end

  def vectors
    self.class.vectors
  end

  def hex(str)
    [str].pack('H*')
  end

  def to_hex(bytes)
    bytes.unpack1('H*')
  end

  # ---- rfcChecks -----------------------------------------------------------

  def test_rfc7748_x25519
    r = vectors['rfcChecks']['rfc7748_6_1']
    base = "\x09".b + ("\x00".b * 31)
    assert_equal r['alicePublicHex'], to_hex(Qf1.x25519(hex(r['alicePrivateHex']), base))
    assert_equal r['bobPublicHex'], to_hex(Qf1.x25519(hex(r['bobPrivateHex']), base))
    assert_equal r['sharedSecretHex'], to_hex(Qf1.x25519(hex(r['alicePrivateHex']), hex(r['bobPublicHex'])))
    assert_equal r['sharedSecretHex'], to_hex(Qf1.x25519(hex(r['bobPrivateHex']), hex(r['alicePublicHex'])))
  end

  def test_rfc5869_hkdf_from_hmac
    r = vectors['rfcChecks']['rfc5869_A_1']
    prk = Qf1.hkdf_extract(hex(r['saltHex']), hex(r['ikmHex']))
    assert_equal r['prkHex'], to_hex(prk)
    assert_equal r['okmHex'], to_hex(Qf1.hkdf_expand(prk, hex(r['infoHex']), r['length']))
  end

  # Cross-check the hand-written HKDF against OpenSSL's where this build has it.
  def test_hkdf_matches_openssl_kdf_where_available
    skip 'OpenSSL::KDF.hkdf not available on this build' unless defined?(OpenSSL::KDF) && OpenSSL::KDF.respond_to?(:hkdf)

    vectors['positive'].each do |p|
      ours = Qf1.hkdf_expand(Qf1.hkdf_extract(hex(p['hkdfSaltHex']), hex(p['sharedSecretHex'])), Qf1::HKDF_INFO, 44)
      theirs = OpenSSL::KDF.hkdf(hex(p['sharedSecretHex']), salt: hex(p['hkdfSaltHex']), info: Qf1::HKDF_INFO,
                                                            length: 44, hash: 'SHA256')
      assert_equal to_hex(theirs), to_hex(ours), p['name']
    end
  end

  def test_constants_match_the_vectors
    c = vectors['constants']
    assert_equal c['hkdfInfoHex'], to_hex(Qf1::HKDF_INFO)
    assert_equal c['okmLength'], Qf1::OKM_LENGTH
    assert_equal c['privateKeyPrefix'], Qf1::PRIVATE_KEY_PREFIX
  end

  # ---- keysets[] -------------------------------------------------------------

  def test_keysets_parse_to_their_fingerprints
    vectors['keysets'].each do |ks|
      held = Qf1.parse_keyset_env(ks['name'], ks['envValue'])
      assert_equal ks['keys'].map { |k| k['fingerprint'] }.sort, held.keys.sort, ks['name']
      ks['keys'].each do |k|
        assert_equal k['privateKeyHex'], to_hex(Qf1.parse_private_key_entry(k['privateKeyEntry']))
        key = held.fetch(k['fingerprint'])
        assert_equal k['publicKeyHex'], to_hex(key.public_key), k['label']
        assert_equal k['fingerprint'], Qf1.fingerprint(key.public_key), k['label']
      end
    end
  end

  # ---- positive[] ------------------------------------------------------------

  def test_positive_cases_decrypt
    env = vectors['positiveEnv']
    assert_equal 9, vectors['positive'].size
    vectors['positive'].each do |p|
      plaintext = Qf1.decrypt(p['ciphertext'], env)
      assert_equal p['plaintext'], plaintext, p['name']
      assert_equal Encoding::UTF_8, plaintext.encoding, p['name']
      assert plaintext.valid_encoding?, p['name']
      assert_equal p['plaintextHex'], to_hex(plaintext.b), p['name']
    end
  end

  # Every intermediate of spec 5 from the vector's fixed ephemeral key.
  def test_positive_cases_reproduce_every_intermediate
    base = "\x09".b + ("\x00".b * 31)
    vectors['positive'].each do |p|
      name = p['name']
      priv_e = hex(p['ephemeralPrivateKeyHex'])
      pub_r = hex(p['recipientPublicKeyHex'])
      e = Qf1.x25519(priv_e, base)
      assert_equal p['ephemeralPublicKeyHex'], to_hex(e), name

      recipient_priv = Qf1.parse_private_key_entry(p['recipientPrivateKeyEntry'])
      assert_equal p['recipientPublicKeyHex'], to_hex(Qf1.public_key_from_private(recipient_priv)), name
      assert_equal p['fingerprint'], Qf1.fingerprint(pub_r), name

      s = Qf1.x25519(priv_e, pub_r)
      assert_equal p['sharedSecretHex'], to_hex(s), name
      assert_equal p['sharedSecretHex'], to_hex(Qf1.x25519(recipient_priv, e)), name

      derived = Qf1.derive(s, e, pub_r)
      assert_equal p['hkdfSaltHex'], to_hex(derived[:salt]), name
      assert_equal p['hkdfInfoHex'], to_hex(Qf1::HKDF_INFO), name
      assert_equal p['prkHex'], to_hex(derived[:prk]), name
      assert_equal p['okmHex'], to_hex(derived[:okm]), name
      assert_equal p['aesKeyHex'], to_hex(derived[:key]), name
      assert_equal p['nonceHex'], to_hex(derived[:nonce]), name

      parsed = Qf1.parse(p['ciphertext'])
      assert_equal p['aadAscii'], parsed.aad, name
      assert_equal p['aadHex'], to_hex(parsed.aad), name
      assert_equal p['keyset'], parsed.keyset, name
      assert_equal p['fingerprint'], parsed.fingerprint, name
      assert_equal p['ephemeralPublicKeyHex'], to_hex(parsed.ephemeral_public_key), name
      assert_equal p['ciphertextAndTagHex'], to_hex(parsed.ciphertext_and_tag), name

      # Seal with the derived key and nonce: byte for byte the vector's blob.
      cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
      cipher.key = derived[:key]
      cipher.iv = derived[:nonce]
      cipher.auth_data = parsed.aad
      pt = hex(p['plaintextHex'])
      sealed = (pt.empty? ? ''.b : cipher.update(pt)) + cipher.final + cipher.auth_tag
      assert_equal p['ciphertextAndTagHex'], to_hex(sealed), name
      assert_equal p['blobHex'], to_hex(e + sealed), name
      assert_equal p['ciphertext'], "#{parsed.aad}#{Qf1.encode_base64url(e + sealed)}", name
    end
  end

  # ---- decryptOnly[] ---------------------------------------------------------

  def test_decrypt_only_cases_decrypt
    refute_empty vectors['decryptOnly']
    vectors['decryptOnly'].each do |d|
      plaintext = Qf1.decrypt(d['ciphertext'], d['env'])
      assert_equal d['plaintext'], plaintext, d['name']
      assert_equal d['plaintextHex'], to_hex(plaintext.b), d['name']
    end
  end

  # ---- negative[] ------------------------------------------------------------

  def test_every_negative_case_fails_with_its_class
    negatives = vectors['negative']
    assert_equal 58, negatives.size
    negatives.each do |n|
      err = assert_raises(Qf1::Error, n['name']) { Qf1.decrypt(n['ciphertext'], n['env']) }
      assert_equal n['expectedError'], err.code, "#{n['name']}: #{err.message}"
      assert err.message.start_with?("qf1 #{n['expectedError']}: "), "#{n['name']}: #{err.message}"
    end
  end

  # mustReject cases are authentic except for the one rule they test: a build
  # that skips the rule decrypts them. Counted separately so the evidence is
  # explicit.
  def test_must_reject_cases_never_decrypt
    must = vectors['negative'].select { |n| n['mustReject'] }
    assert_equal 34, must.size
    must.each do |n|
      assert_raises(Qf1::Error, n['name']) { Qf1.decrypt(n['ciphertext'], n['env']) }
    end
  end

  # ---- keyEntryCases[] (private entries and env values) ----------------------

  def test_private_key_entry_cases
    cases = vectors['keyEntryCases'].select { |k| k['kind'] == 'privateKeyEntry' }
    assert_equal 7, cases.size
    cases.each do |k|
      if k['expectedHex']
        assert_equal k['expectedHex'], to_hex(Qf1.parse_private_key_entry(k['input'])), k['name']
      else
        err = assert_raises(Qf1::Error, k['name']) { Qf1.parse_private_key_entry(k['input']) }
        assert_equal k['expectedError'], err.code, k['name']
      end
    end
  end

  def test_env_value_cases
    cases = vectors['keyEntryCases'].select { |k| k['kind'] == 'envValue' }
    assert_equal 11, cases.size
    cases.each do |k|
      if k['expectedFingerprints']
        held = Qf1.parse_keyset_env(k['keyset'], k['input'])
        assert_equal k['expectedFingerprints'].sort, held.keys.sort, k['name']
      else
        err = assert_raises(Qf1::Error, k['name']) { Qf1.parse_keyset_env(k['keyset'], k['input']) }
        assert_equal k['expectedError'], err.code, k['name']
      end
    end
  end

  # ---- spec rules the vectors pin only indirectly ----------------------------

  def test_unset_keyset_is_keyset_missing_and_names_the_keyset
    err = assert_raises(Qf1::Error) { Qf1.parse_keyset_env('QUONFIG_KEYSET_PROD', nil) }
    assert_equal 'keyset_missing', err.code
    assert_includes err.message, 'QUONFIG_KEYSET_PROD'
  end

  # Spec 9.2: the bad entry is named by its 1-based position among the
  # non-empty pieces left after the trim, never by content.
  def test_keyset_invalid_names_the_position_only
    good = vectors['keysets'].find { |ks| ks['name'] == 'QUONFIG_KEYSET_TEST' }['envValue']
    err = assert_raises(Qf1::Error) { Qf1.parse_keyset_env('QUONFIG_KEYSET_TEST', " , #{good},,\n, not-a-key-xyz ,") }
    assert_equal 'keyset_invalid', err.code
    assert_includes err.message, 'entry 2'
    refute_includes err.message, 'not-a-key-xyz'
    refute_includes err.message, good
  end

  def test_key_not_held_names_needed_and_held_fingerprints
    n = vectors['negative'].find { |x| x['name'] == 'fingerprint-not-held' }
    err = assert_raises(Qf1::Error) { Qf1.decrypt(n['ciphertext'], n['env']) }
    parsed_fp = n['ciphertext'].split(':', -1)[2]
    assert_includes err.message, parsed_fp
    assert_includes err.message, 'b3f48931'
    assert_includes err.message, 'QUONFIG_KEYSET_TEST'
    assert_equal parsed_fp, err.fingerprint
    assert_equal ['b3f48931'], err.held
  end

  # The env var named by an invalid keyset is never read (spec 2).
  def test_invalid_keyset_name_never_reads_the_env
    n = vectors['negative'].find { |x| x['name'] == 'keyset-name-HOME' }
    reads = []
    env = Object.new
    env.define_singleton_method(:[]) do |name|
      reads << name
      n['env'][name]
    end
    err = assert_raises(Qf1::Error) { Qf1.decrypt(n['ciphertext'], env) }
    assert_equal 'invalid_keyset_name', err.code
    assert_empty reads
  end

  # Only the keyset the ciphertext names is read: no other variable.
  def test_decrypt_reads_only_the_named_keyset
    p = vectors['positive'].first
    reads = []
    env = Object.new
    env.define_singleton_method(:[]) do |name|
      reads << name
      TestQf1.vectors['positiveEnv'][name]
    end
    Qf1.decrypt(p['ciphertext'], env)
    assert_equal [p['keyset']], reads.uniq
  end

  def test_invalid_keyset_name_quote_is_truncated_and_escaped
    name = "QUONFIG_KEYSET_#{'x' * 80}\u0007"
    value = "qf1:#{name}:b3f48931:#{'A' * 64}"
    err = assert_raises(Qf1::Error) { Qf1.parse(value) }
    assert_equal 'invalid_keyset_name', err.code
    refute_includes err.message, "\u0007"
    refute_includes err.message, 'x' * 60
  end

  def test_non_string_value_is_malformed
    [nil, 42, :sym, ['qf1:a']].each do |v|
      err = assert_raises(Qf1::Error) { Qf1.parse(v) }
      assert_equal 'malformed', err.code
    end
  end

  def test_invalid_utf8_input_strings_are_malformed_not_argument_errors
    err = assert_raises(Qf1::Error) { Qf1.parse("qf1:QUONFIG_KEYSET:b3f48931:\xff".dup.force_encoding('UTF-8')) }
    assert_equal 'malformed', err.code
    err = assert_raises(Qf1::Error) { Qf1.parse_keyset_env('QUONFIG_KEYSET', "\xff".dup.force_encoding('UTF-8')) }
    assert_equal 'keyset_invalid', err.code
  end

  # A cached keyset follows the env var's current value (ITD cases share a
  # process and some read a secret with no keyset set).
  def test_keyset_cache_follows_the_current_env_value
    p = vectors['positive'].first
    env = vectors['positiveEnv'].dup
    assert_equal p['plaintext'], Qf1.decrypt(p['ciphertext'], env)
    env.delete(p['keyset'])
    err = assert_raises(Qf1::Error) { Qf1.decrypt(p['ciphertext'], env) }
    assert_equal 'keyset_missing', err.code
    env[p['keyset']] = vectors['positiveEnv']['QUONFIG_KEYSET']
    err = assert_raises(Qf1::Error) { Qf1.decrypt(p['ciphertext'], env) }
    assert_equal 'key_not_held', err.code
    env[p['keyset']] = vectors['positiveEnv'][p['keyset']]
    assert_equal p['plaintext'], Qf1.decrypt(p['ciphertext'], env)
  end

  # A small-order refusal from OpenSSL is the all-zero failure (spec 5.2); any
  # other library error propagates.
  def test_only_the_derivation_refusal_maps_to_all_zero
    assert_equal "\x00".b * 32, Qf1.x25519("\x01".b * 32, "\x00".b * 32)
    assert Qf1.derivation_refusal?(OpenSSL::PKey::PKeyError.new('EVP_PKEY_derive: failed during derivation'))
    refute Qf1.derivation_refusal?(OpenSSL::PKey::PKeyError.new('something else entirely'))
    refute Qf1.derivation_refusal?(ArgumentError.new('failed during derivation'))
  end

  def test_wrong_length_x25519_input_is_a_bug_not_all_zero
    assert_raises(ArgumentError) { Qf1.x25519("\x01".b * 31, "\x09".b * 32) }
  end
end
