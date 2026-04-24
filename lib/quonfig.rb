# frozen_string_literal: true

module Quonfig
  NO_DEFAULT_PROVIDED = :no_default_provided
  VERSION = File.read(File.dirname(__FILE__) + '/../VERSION').strip
end

begin
  require 'semantic_logger'
rescue LoadError
  # semantic_logger is optional - only needed for dynamic log level filtering
end

require 'securerandom'
require 'concurrent/atomics'
require 'concurrent'
require 'faraday'
require 'openssl'
require 'ld-eventsource'

require 'quonfig/internal_logger'
require 'quonfig/time_helpers'
require 'quonfig/types'
require 'quonfig/error'
require 'quonfig/duration'
require 'quonfig/reason'
require 'quonfig/evaluation'
require 'quonfig/encryption'
require 'quonfig/exponential_backoff'
require 'quonfig/periodic_sync'
require 'quonfig/errors/initialization_timeout_error'
require 'quonfig/errors/invalid_sdk_key_error'
require 'quonfig/errors/missing_default_error'
require 'quonfig/errors/env_var_parse_error'
require 'quonfig/errors/missing_env_var_error'
require 'quonfig/errors/type_mismatch_error'
require 'quonfig/errors/uninitialized_error'
require 'quonfig/options'
require 'quonfig/rate_limit_cache'
require 'quonfig/weighted_value_resolver'
require 'quonfig/config_store'
require 'quonfig/evaluator'
require 'quonfig/resolver'
require 'quonfig/config_envelope'
require 'quonfig/config_loader'
require 'quonfig/datadir'
require 'quonfig/sse_config_client'
require 'quonfig/http_connection'
require 'quonfig/caching_http_connection'
require 'quonfig/context'
require 'quonfig/telemetry/context_shape'
require 'quonfig/telemetry/context_shape_aggregator'
require 'quonfig/telemetry/example_contexts_aggregator'
require 'quonfig/telemetry/evaluation_summaries_aggregator'
require 'quonfig/telemetry/telemetry_reporter'
require 'quonfig/client'
require 'quonfig/bound_client'
require 'quonfig/semantic_logger_filter'
require 'quonfig/stdlib_formatter'
require 'quonfig/quonfig'
require 'quonfig/murmer3'
require 'quonfig/semver'
require 'quonfig/fixed_size_hash'
