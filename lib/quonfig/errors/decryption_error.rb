# frozen_string_literal: true

module Quonfig
  module Errors
    # Raised when a confidential config's ciphertext cannot be decrypted —
    # either the configured `decryptWith` key is missing/empty, or the
    # AES-GCM payload itself is malformed/tampered.
    #
    # Mirrors sdk-python's QuonfigDecryptionError. Sdk-node currently
    # raises plain `Error` for the same path; this class is the Ruby
    # equivalent of the dedicated exception type.
    class DecryptionError < Quonfig::Error
      def initialize(key, cause = nil)
        message = "Decryption failed for config '#{key}'"
        message += ": #{cause}" if cause && !cause.to_s.empty?
        super(message)
      end
    end
  end
end
