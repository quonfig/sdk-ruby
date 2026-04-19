# frozen_string_literal: true

class MockBaseClient
  STAGING_ENV_ID = 1
  PRODUCTION_ENV_ID = 2
  TEST_ENV_ID = 3
  attr_reader :namespace, :logger, :config_client, :options, :posts

  def initialize(options = Quonfig::Options.new)
    @options = options
    @namespace = namespace
    @config_client = MockConfigClient.new
    @posts = []
  end

  def instance_hash
    'mock-base-client-instance-hash'
  end

  def project_id
    1
  end

  def post(_, _)
    raise 'Use wait_for_post_requests'
  end

  def log
    @logger
  end

  def context_shape_aggregator; end

  def evaluation_summary_aggregator; end

  def example_contexts_aggregator; end

  def config_value(key)
    @config_values[key]
  end
end
