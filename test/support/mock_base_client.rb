# frozen_string_literal: true

# Minimal stand-in for Quonfig::Client used by Evaluator/ConfigLoader tests.
# We deliberately keep this tiny so the tests don't depend on the live
# ConfigStore/Resolver/Evaluator wiring — they exercise their target in
# isolation.
class MockBaseClient
  STAGING_ENV_ID = 1
  PRODUCTION_ENV_ID = 2
  TEST_ENV_ID = 3

  attr_reader :options

  def initialize(options = Quonfig::Options.new)
    @options = options
  end

  def instance_hash
    'mock-base-client-instance-hash'
  end

  def project_id
    1
  end

  def log; end
end
