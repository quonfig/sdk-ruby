# frozen_string_literal: true

module Quonfig
  module Errors
    # Raised when a secret cannot be decrypted: every qf1 reader failure
    # (spec classes malformed, unsupported_version, invalid_keyset_name,
    # keyset_missing, keyset_invalid, key_not_held, invalid_ephemeral_key,
    # decrypt_failed), and a value that still carries the old `decryptWith`
    # field, which this SDK no longer reads.
    #
    # The message names the config key and, for qf1 failures, the class
    # (`qf1 key_not_held: ...`), keyset and fingerprints. It never contains
    # key material, keyset env values, the ciphertext payload or plaintext.
    #
    # Mirrors sdk-python's QuonfigDecryptionError.
    class DecryptionError < Quonfig::Error
      # The qf1 error class name (for example "key_not_held"), or nil when
      # the failure is not a qf1 one (a leftover decryptWith value).
      attr_reader :qf1_code

      def initialize(key, cause = nil)
        message = "Decryption failed for config '#{key}'"
        message += ": #{cause}" if cause && !cause.to_s.empty?
        @qf1_code = cause.respond_to?(:code) ? cause.code : nil
        super(message)
      end
    end
  end
end
