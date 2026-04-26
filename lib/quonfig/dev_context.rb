# frozen_string_literal: true

require 'json'

module Quonfig
  # Dev-only context loader. Reads ~/.quonfig/tokens.json (written by
  # `qfg login`) and returns {'quonfig-user' => {'email' => ...}} when a
  # userEmail is present. Returns nil when the file is missing, unreadable,
  # or has no userEmail.
  #
  # The attribute is dev-only by construction: production servers do not
  # run `qfg login` and therefore have no tokens file. Rules keyed on
  # `quonfig-user.email` are dead code in prod.
  module DevContext
    TOKENS_BASENAME = File.join('.quonfig', 'tokens.json')

    def self.load_quonfig_user_context
      path = File.join(Dir.home, TOKENS_BASENAME)
      return nil unless File.exist?(path)

      raw = begin
        File.read(path)
      rescue StandardError
        return nil
      end

      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError => e
        warn "[quonfig] dev-context: could not parse #{path} (#{e.message}); skipping injection"
        return nil
      end

      email = parsed.is_a?(Hash) ? parsed['userEmail'] : nil
      return nil unless email.is_a?(String) && !email.empty?

      { 'quonfig-user' => { 'email' => email } }
    end
  end
end
