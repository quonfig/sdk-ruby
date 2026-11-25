# frozen_string_literal: true

require 'json'

# The qf1 known-answer vectors (spec section 14), read from the sibling
# integration-test-data checkout CI uses. TEST KEYS ONLY; nothing is copied
# into this repo.
module Qf1Vectors
  PATH = File.expand_path('../../../integration-test-data/tests/secrets/qf1-vectors.json', __dir__)

  def self.load
    @load ||= begin
      unless File.exist?(PATH)
        raise "[qf1 tests] vectors not found at #{PATH}: clone quonfig/integration-test-data " \
              'as a sibling of sdk-ruby (CI checks it out there).'
      end

      JSON.parse(File.read(PATH, encoding: 'UTF-8'))
    end
  end
end
