# frozen_string_literal: true

module Quonfig
  class Encryption
    CIPHER_TYPE = "aes-256-gcm" # 32/12
    SEPARATOR = "--"
    AUTH_TAG_LENGTH = 16

    # Hexadecimal format ensures that generated keys are representable with
    # plain text
    #
    # To convert back to the original string with the desired length:
    #   [ value ].pack("H*")
    def self.generate_new_hex_key
      generate_random_key.unpack("H*")[0]
    end

    def initialize(key_string_hex)
      @key = [key_string_hex].pack("H*")
    end

    def encrypt(clear_text)
      cipher = OpenSSL::Cipher.new(CIPHER_TYPE)
      cipher.encrypt
      iv = cipher.random_iv

      # load them into the cipher
      cipher.key = @key
      cipher.iv = iv
      cipher.auth_data = ""

      # encrypt the message
      encrypted = cipher.update(clear_text)
      encrypted << cipher.final
      tag = cipher.auth_tag
      
      # pack and join
      [encrypted, iv, tag].map { |p| p.unpack("H*")[0] }.join(SEPARATOR)
    end

    def decrypt(encrypted_string)
      encrypted_data, iv, auth_tag = encrypted_string.split(SEPARATOR).map { |p| [p].pack("H*") }
      
      # Currently the OpenSSL bindings do not raise an error if auth_tag is
      # truncated, which would allow an attacker to easily forge it. See
      # https://github.com/ruby/openssl/issues/63
      if auth_tag.bytesize != AUTH_TAG_LENGTH
        raise "truncated auth_tag"
      end

      cipher = OpenSSL::Cipher.new(CIPHER_TYPE)
      cipher.decrypt
      cipher.key = @key
      cipher.iv = iv
  
      cipher.auth_tag = auth_tag
     
      # and decrypt it
      decrypted = cipher.update(encrypted_data)
      decrypted << cipher.final
      decrypted
    end

    private

    def self.generate_random_key
      SecureRandom.random_bytes(key_length)
    end

    def self.key_length
      OpenSSL::Cipher.new(CIPHER_TYPE).key_len
    end
  end
end
