# frozen_string_literal: true

require 'test_helper'

class TestEncryption < Minitest::Test
  def test_encryption
    secret = Quonfig::Encryption.generate_new_hex_key

    enc = Quonfig::Encryption.new(secret)

    clear_text = "hello world"
    encrypted = enc.encrypt(clear_text)
    decrypted = enc.decrypt(encrypted)
    assert_equal clear_text, decrypted
  end
end
