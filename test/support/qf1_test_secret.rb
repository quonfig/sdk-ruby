# frozen_string_literal: true

require 'digest'
require 'openssl'
require 'securerandom'

# Test-only qf1 writer (the SDK reads only). Keys are derived at run time
# from a public label, the way integration-test-data's qf1_test_keyset helper
# derives them, so no key material is committed: TEST KEYS ONLY.
module Qf1TestSecret
  module_function

  def private_key(label)
    Digest::SHA256.digest("qf1 test vector private key: #{label}")
  end

  def private_entry(label)
    "qf1-priv-#{Quonfig::Qf1.encode_base64url(private_key(label))}"
  end

  # Encrypt +plaintext+ to the key with +label+ on +keyset+ (spec 7).
  def seal(keyset, label, plaintext)
    qf1 = Quonfig::Qf1
    pub_r = qf1.public_key_from_private(private_key(label))
    priv_e = SecureRandom.random_bytes(32)
    e = qf1.public_key_from_private(priv_e)
    derived = qf1.derive(qf1.x25519(priv_e, pub_r), e, pub_r)
    header = "qf1:#{keyset}:#{qf1.fingerprint(pub_r)}:"
    cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
    cipher.key = derived[:key]
    cipher.iv = derived[:nonce]
    cipher.auth_data = header
    pt = plaintext.b
    sealed = (pt.empty? ? ''.b : cipher.update(pt)) + cipher.final + cipher.auth_tag
    "#{header}#{qf1.encode_base64url(e + sealed)}"
  end
end
