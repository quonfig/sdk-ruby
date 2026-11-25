# frozen_string_literal: true

require 'openssl'
require 'digest'

module Quonfig
  # qf1 secrets reader (qfg-8seuf.11). Normative spec:
  # project/plans/secrets-qf1-spec.md (approved 2026-11-24).
  #
  #   qf1:<KEYSET>:<FINGERPRINT>:<base64url-no-pad(E || C || T)>
  #   X25519 (RFC 7748) + HKDF-SHA256 (RFC 5869, written out from HMAC) +
  #   AES-256-GCM, with the header `qf1:<KEYSET>:<FINGERPRINT>:` as the AAD.
  #
  # The private key is looked up by (keyset name, fingerprint) in the env var
  # named by the keyset; keys are never tried one after another. Read side
  # only: this SDK never encrypts.
  #
  # Error text follows spec 9.2: it names keysets, fingerprints and entry
  # positions, never key material, env values, the payload or plaintext.
  #
  # Every input is handled as bytes (ASCII-8BIT), so an invalid-UTF-8 string
  # is a parse failure, never an ArgumentError from a regex.
  #
  # @api private
  module Qf1
    # A reader failure. +code+ is the spec 9.1 class name.
    class Error < StandardError
      attr_reader :code, :keyset, :fingerprint, :held, :entry

      def initialize(code, detail, keyset: nil, fingerprint: nil, held: nil, entry: nil)
        @code = code
        @keyset = keyset
        @fingerprint = fingerprint
        @held = held
        @entry = entry
        super("qf1 #{code}: #{detail}")
      end
    end

    HeldKey = Struct.new(:private_key, :public_key)
    Parsed = Struct.new(:keyset, :fingerprint, :ephemeral_public_key, :ciphertext_and_tag, :aad)

    HKDF_INFO = 'quonfig.com/qf1/X25519'.b.freeze
    OKM_LENGTH = 44
    TAG_LENGTH = 16
    MIN_PAYLOAD = 48
    PRIVATE_KEY_PREFIX = 'qf1-priv-'
    ENTRY_BODY_LENGTH = 43

    # Full-string matches (\A...\z): Ruby's ^ and $ are line anchors.
    KEYSET_NAME_RE = /\AQUONFIG_KEYSET(?:_[A-Z0-9]+)*\z/n
    KEYSET_NAME_PATTERN = '^QUONFIG_KEYSET(_[A-Z0-9]+)*$'
    FINGERPRINT_RE = /\A[0-9a-f]{8}\z/n
    BASE64URL_RE = /\A[A-Za-z0-9_-]+\z/n
    OTHER_VERSION_RE = /\Aqf[1-9][0-9]*:/n
    # Spec 6.2: strip ONLY space, tab, CR and LF (never String#strip, which
    # also removes NUL, VT and FF).
    ENV_TRIM_LEADING_RE = /\A[ \t\r\n]+/n
    ENV_TRIM_TRAILING_RE = /[ \t\r\n]+\z/n

    PKCS8_X25519_PREFIX = ['302e020100300506032b656e04220420'].pack('H*').freeze
    SPKI_X25519_PREFIX = ['302a300506032b656e032100'].pack('H*').freeze
    BASE_POINT = ("\x09".b + ("\x00".b * 31)).freeze
    ZERO32 = ("\x00".b * 32).freeze
    KEYSET_CACHE_MAX = 64

    @keyset_cache = {}
    @keyset_cache_mutex = Mutex.new
    @supported = nil

    module_function

    # Decrypt the stored value +value+ (spec 8). +env+ answers #[] with the
    # value of an env var or nil (ENV, a Hash). Only the env var named by the
    # ciphertext's keyset is read, and only after that name passes spec 2.
    # Returns a valid UTF-8 String; raises Qf1::Error.
    def decrypt(value, env = ENV)
      parsed = parse(value)
      ensure_supported!
      held = keyset(parsed.keyset, env[parsed.keyset], needed: parsed.fingerprint)
      key = held[parsed.fingerprint]
      if key.nil?
        fps = held.keys.sort
        raise Error.new('key_not_held',
                        "value is encrypted to #{parsed.keyset} fingerprint #{parsed.fingerprint}; " \
                        "this runtime holds #{parsed.keyset} fingerprints [#{fps.join(', ')}]",
                        keyset: parsed.keyset, fingerprint: parsed.fingerprint, held: fps)
      end

      shared = x25519(key.private_key, parsed.ephemeral_public_key)
      if shared == ZERO32
        raise Error.new('invalid_ephemeral_key',
                        "the ephemeral key of a value on #{parsed.keyset} fingerprint #{parsed.fingerprint} " \
                        'gives an all-zero shared secret', keyset: parsed.keyset, fingerprint: parsed.fingerprint)
      end

      derived = derive(shared, parsed.ephemeral_public_key, key.public_key)
      plaintext = open_gcm(derived[:key], derived[:nonce], parsed.aad, parsed.ciphertext_and_tag)
      if plaintext.nil?
        raise Error.new('decrypt_failed',
                        "authentication failed for a value on #{parsed.keyset} fingerprint #{parsed.fingerprint}",
                        keyset: parsed.keyset, fingerprint: parsed.fingerprint)
      end

      # Strict UTF-8 (spec 3.3): reject, never replace; a leading BOM stays.
      plaintext.force_encoding(Encoding::UTF_8)
      unless plaintext.valid_encoding?
        raise Error.new('decrypt_failed',
                        "the value on #{parsed.keyset} fingerprint #{parsed.fingerprint} is not valid UTF-8",
                        keyset: parsed.keyset, fingerprint: parsed.fingerprint)
      end

      plaintext
    end

    # Spec 3.5, in order: the first failing step decides the class. Does not
    # reject a small-order E (decrypt checks the shared secret instead).
    def parse(value)
      raise Error.new('malformed', 'value is not a string') unless value.is_a?(String)

      text = value.b
      unless text.start_with?('qf1:')
        raise Error.new('unsupported_version', 'value uses a qf1 format version this SDK does not read') if text.match?(OTHER_VERSION_RE)

        raise Error.new('malformed', 'value does not start with "qf1:"')
      end

      fields = text.split(':', -1)
      raise Error.new('malformed', "value has #{fields.size} colon-separated fields, expected 4") unless fields.size == 4

      _version, keyset_name, fp, payload_text = fields
      unless keyset_name.match?(KEYSET_NAME_RE)
        raise Error.new('invalid_keyset_name',
                        "keyset name #{quote_untrusted(keyset_name)} does not match #{KEYSET_NAME_PATTERN}")
      end
      raise Error.new('malformed', 'fingerprint is not 8 lowercase hex characters') unless fp.match?(FINGERPRINT_RE)

      payload = decode_base64url(payload_text)
      raise Error.new('malformed', 'payload is not canonical unpadded base64url') if payload.nil?
      raise Error.new('malformed', "payload is #{payload.bytesize} bytes, below the #{MIN_PAYLOAD}-byte minimum") if payload.bytesize < MIN_PAYLOAD

      ephemeral = payload.byteslice(0, 32)
      raise Error.new('malformed', 'ephemeral key has its top bit set') if ephemeral.getbyte(31).anybits?(0x80)

      keyset_name = keyset_name.dup.force_encoding(Encoding::US_ASCII).freeze
      fp = fp.dup.force_encoding(Encoding::US_ASCII).freeze
      aad = "qf1:#{keyset_name}:#{fp}:".b.freeze
      Parsed.new(keyset_name, fp, ephemeral, payload.byteslice(32, payload.bytesize - 32), aad)
    end

    # Spec 6.2 with a cache keyed on the env var's CURRENT value, so a changed
    # (or removed) variable is never answered from an old parse. Only
    # successful parses are cached.
    def keyset(name, value, needed: nil)
      raise Error.new('keyset_missing', missing_detail(name, needed), keyset: name) if value.nil?

      cache_key = [name, value].freeze
      cached = @keyset_cache_mutex.synchronize { @keyset_cache[cache_key] }
      return cached if cached

      held = parse_keyset_env(name, value, needed: needed)
      @keyset_cache_mutex.synchronize do
        @keyset_cache.clear if @keyset_cache.size >= KEYSET_CACHE_MAX
        @keyset_cache[[name, value.dup.freeze].freeze] = held
      end
      held
    end

    def clear_keyset_cache!
      @keyset_cache_mutex.synchronize { @keyset_cache.clear }
    end

    # Parse a keyset env var value (nil = unset) into fingerprint => HeldKey.
    def parse_keyset_env(name, value, needed: nil)
      raise Error.new('keyset_missing', missing_detail(name, needed), keyset: name) if value.nil?

      pieces = value.to_s.b.split(',', -1)
                    .map { |piece| piece.sub(ENV_TRIM_LEADING_RE, '').sub(ENV_TRIM_TRAILING_RE, '') }
                    .reject(&:empty?)
      raise Error.new('keyset_missing', "#{name} is set but holds no keys", keyset: name) if pieces.empty?

      held = {}
      pieces.each_with_index do |piece, index|
        private_key =
          begin
            parse_private_key_entry(piece)
          rescue Error => e
            raise unless e.code == 'invalid_key_entry'

            raise Error.new('keyset_invalid', "#{name} entry #{index + 1} is not a qf1 private key",
                            keyset: name, entry: index + 1), cause: nil
          end

        public_key = public_key_from_private(private_key)
        fp = fingerprint(public_key)
        existing = held[fp]
        if existing
          next if existing.public_key == public_key # one key, written twice or clamp-equivalent

          raise Error.new('keyset_invalid', "#{name} holds two different keys with fingerprint #{fp}",
                          keyset: name, fingerprint: fp)
        end
        held[fp] = HeldKey.new(private_key.freeze, public_key.freeze).freeze
      end
      held.freeze
    end

    # Spec 6.1: `qf1-priv-` + exactly 43 canonical base64url characters (32
    # bytes, stored unclamped). Returns the 32 raw bytes.
    def parse_private_key_entry(entry)
      text = entry.is_a?(String) ? entry.b : nil
      raise Error.new('invalid_key_entry', "private key entry does not start with \"#{PRIVATE_KEY_PREFIX}\"") unless text&.start_with?(PRIVATE_KEY_PREFIX)

      body = text.byteslice(PRIVATE_KEY_PREFIX.bytesize, text.bytesize)
      bytes = body.bytesize == ENTRY_BODY_LENGTH ? decode_base64url(body) : nil
      unless bytes && bytes.bytesize == 32
        raise Error.new('invalid_key_entry',
                        "private key entry is not \"#{PRIVATE_KEY_PREFIX}\" followed by #{ENTRY_BODY_LENGTH} " \
                        'canonical base64url characters')
      end

      bytes
    end

    # Spec 3.4: unpadded RFC 4648 section 5, strictly. nil on any failure.
    def decode_base64url(text)
      return nil if text.empty? || !text.match?(BASE64URL_RE) || text.bytesize % 4 == 1

      padded = text.tr('-_', '+/')
      padded += '=' * ((4 - (padded.bytesize % 4)) % 4)
      bytes = padded.unpack1('m0')
      encode_base64url(bytes) == text ? bytes : nil
    rescue ArgumentError
      nil
    end

    def encode_base64url(bytes)
      [bytes].pack('m0').tr('+/', '-_').delete('=')
    end

    # Spec 4: lowercase hex of SHA-256(pub)[0:4].
    def fingerprint(public_key)
      Digest::SHA256.digest(public_key).byteslice(0, 4).unpack1('H*')
    end

    def public_key_from_private(private_key)
      x25519(private_key, BASE_POINT)
    end

    # X25519(scalar, u) per RFC 7748 (OpenSSL clamps, masks and reduces). The
    # keys are built from DER: OpenSSL::PKey.new_raw_private_key is missing
    # from older openssl gems. OpenSSL refuses a small-order input with
    # "failed during derivation"; ONLY that refusal becomes 32 zero bytes, so
    # the caller's all-zero check covers both behaviours (spec 5.2). Any other
    # error propagates as the bug it is.
    def x25519(scalar, u)
      raise ArgumentError, 'x25519 needs 32-byte inputs' unless scalar.bytesize == 32 && u.bytesize == 32

      private_key = OpenSSL::PKey.read(PKCS8_X25519_PREFIX + scalar.b)
      public_key = OpenSSL::PKey.read(SPKI_X25519_PREFIX + u.b)
      begin
        private_key.derive(public_key).b
      rescue OpenSSL::PKey::PKeyError => e
        raise unless derivation_refusal?(e)

        ZERO32.dup
      end
    end

    def derivation_refusal?(error)
      error.is_a?(OpenSSL::PKey::PKeyError) && error.message.include?('failed during derivation')
    end

    # Spec 5.3: salt = E || pub_r (E as transmitted), PRK = HMAC(salt, S),
    # OKM = Expand(PRK, INFO, 44), K = OKM[0:32], N = OKM[32:44].
    def derive(shared, ephemeral_public_key, recipient_public_key)
      salt = ephemeral_public_key.b + recipient_public_key.b
      prk = hkdf_extract(salt, shared)
      okm = hkdf_expand(prk, HKDF_INFO, OKM_LENGTH)
      { salt: salt, prk: prk, okm: okm, key: okm.byteslice(0, 32), nonce: okm.byteslice(32, 12) }
    end

    # RFC 5869 2.2 Extract, written out from HMAC (not OpenSSL::KDF, which is
    # absent on LibreSSL builds).
    def hkdf_extract(salt, ikm)
      salt = ("\x00".b * 32) if salt.empty?
      OpenSSL::HMAC.digest('SHA256', salt, ikm)
    end

    # RFC 5869 2.3 Expand: T(i) = HMAC(PRK, T(i-1) || info || i).
    def hkdf_expand(prk, info, length)
      raise ArgumentError, 'HKDF length out of range' if length.negative? || length > 255 * 32

      okm = ''.b
      t = ''.b
      i = 1
      while okm.bytesize < length
        t = OpenSSL::HMAC.digest('SHA256', prk, t + info.b + i.chr.b)
        okm << t
        i += 1
      end
      okm.byteslice(0, length)
    end

    # AES-256-GCM open. nil when the tag does not verify; no plaintext is
    # returned before it does.
    def open_gcm(key, nonce, aad, ciphertext_and_tag)
      ciphertext = ciphertext_and_tag.byteslice(0, ciphertext_and_tag.bytesize - TAG_LENGTH)
      tag = ciphertext_and_tag.byteslice(ciphertext_and_tag.bytesize - TAG_LENGTH, TAG_LENGTH)
      cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
      cipher.key = key
      cipher.iv = nonce
      cipher.auth_tag = tag
      cipher.auth_data = aad
      # Cipher#update refuses an empty string; the empty plaintext is valid.
      out = ciphertext.empty? ? ''.b : cipher.update(ciphertext)
      out << cipher.final
      out
    rescue OpenSSL::Cipher::CipherError
      nil
    end

    # True when this OpenSSL build does X25519 through OpenSSL::PKey (Ruby
    # 3.1+ with the openssl gem >= 3.0 on OpenSSL 1.1.1+). Checked lazily, at
    # the first secret read, so a build without it never fails at require.
    def x25519_supported?
      return @supported unless @supported.nil?

      @supported =
        begin
          OpenSSL::PKey::PKey.method_defined?(:derive) &&
            fingerprint(public_key_from_private("\x01".b * 32)).match?(FINGERPRINT_RE)
        rescue StandardError
          false
        end
    end

    def ensure_supported!
      return if x25519_supported?

      raise Error.new('unsupported_platform',
                      'reading secrets needs X25519 in OpenSSL::PKey: Ruby >= 3.1 with the openssl gem >= 3.0 ' \
                      "on OpenSSL 1.1.1 or later (this runtime: Ruby #{RUBY_VERSION}, openssl gem " \
                      "#{OpenSSL::VERSION}, #{OpenSSL::OPENSSL_LIBRARY_VERSION})")
    end

    def missing_detail(name, needed)
      return "this runtime has no #{name}" if needed.nil?

      "value is encrypted to #{name} fingerprint #{needed}; this runtime has no #{name}"
    end

    # Spec 9.2: an invalid keyset name may be quoted, truncated to 64
    # characters, with control (and non-ASCII) bytes escaped.
    def quote_untrusted(name)
      shown = name.b.byteslice(0, 64).each_byte.map do |byte|
        byte < 0x20 || byte >= 0x7f || byte == 0x22 || byte == 0x5c ? format('\\x%02x', byte) : byte.chr
      end.join
      suffix = name.bytesize > 64 ? '...' : ''
      "\"#{shown}\"#{suffix}"
    end
  end
end
