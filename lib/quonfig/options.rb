# frozen_string_literal: true

require 'uri'

module Quonfig
  # Options passed to Quonfig::Client at construction time.
  class Options
    attr_reader :sdk_key, :environment, :api_urls, :sse_api_urls, :telemetry_destination, :config_api_urls,
                :on_no_default, :initialization_timeout_sec, :on_init_failure, :collect_sync_interval, :datadir, :enable_sse, :enable_polling, :poll_interval, :global_context, :logger_key, :logger, :enable_quonfig_user_context
    attr_accessor :is_fork

    module ON_INITIALIZATION_FAILURE
      RAISE = :raise
      RETURN = :return
    end

    module ON_NO_DEFAULT
      RAISE = :raise
      RETURN_NIL = :return_nil
    end

    DEFAULT_MAX_PATHS = 1_000
    DEFAULT_MAX_KEYS = 100_000
    DEFAULT_MAX_EXAMPLE_CONTEXTS = 100_000
    DEFAULT_MAX_EVAL_SUMMARIES = 100_000

    # Hardcoded fallback domain. Overridden by ENV['QUONFIG_DOMAIN'].
    DEFAULT_DOMAIN = 'quonfig.com'

    # Hardcoded fallback API URLs (used only when no QUONFIG_DOMAIN is set
    # and no explicit api_urls are provided). Mirrors derive_api_urls(DEFAULT_DOMAIN).
    DEFAULT_API_URLS = [
      'https://primary.quonfig.com',
      'https://secondary.quonfig.com'
    ].freeze

    # Resolve the active domain. Reads QUONFIG_DOMAIN; falls back to
    # DEFAULT_DOMAIN. Mirrors `cli/src/util/domain-urls.ts#getDomain`.
    def self.domain
      env = ENV.fetch('QUONFIG_DOMAIN', nil)
      env && !env.empty? ? env : DEFAULT_DOMAIN
    end

    # Derive default api_urls for a given domain. e.g. for domain
    # `quonfig-staging.com` returns
    # `["https://primary.quonfig-staging.com", "https://secondary.quonfig-staging.com"]`.
    def self.derive_api_urls(domain)
      [
        "https://primary.#{domain}",
        "https://secondary.#{domain}"
      ]
    end

    # Derive the telemetry URL for a given domain.
    def self.derive_telemetry_url(domain)
      "https://telemetry.#{domain}"
    end

    # Derive the SSE stream URL for a given API URL by prepending `stream.` to
    # the hostname. Preserves scheme, port, and path.
    #
    #   derive_stream_url('https://primary.quonfig.com')
    #     # => 'https://stream.primary.quonfig.com'
    #   derive_stream_url('http://localhost:6550')
    #     # => 'http://stream.localhost:6550'
    def self.derive_stream_url(api_url)
      uri = URI.parse(api_url)
      uri.host = "stream.#{uri.host}" if uri.host
      uri.to_s
    end

    def initialize(options = {})
      init(**options)
    end

    # In datadir mode the SDK evaluates config from a local workspace and does
    # not connect to the delivery service.
    def local_only?
      !@datadir.nil?
    end

    def datadir?
      !@datadir.nil?
    end

    def collect_max_paths
      return 0 unless telemetry_allowed?(true)

      @collect_max_paths
    end

    def collect_max_shapes
      return 0 unless telemetry_allowed?(@collect_shapes)

      @collect_max_shapes
    end

    def collect_max_example_contexts
      return 0 unless telemetry_allowed?(@collect_example_contexts)

      @collect_max_example_contexts
    end

    def collect_max_evaluation_summaries
      return 0 unless telemetry_allowed?(@collect_evaluation_summaries)

      @collect_max_evaluation_summaries
    end

    def sdk_key_id
      @sdk_key&.split('-')&.first
    end

    def for_fork
      clone = self.clone
      clone.is_fork = true
      clone
    end

    private

    def init(
      api_urls: nil,
      telemetry_url: nil,
      sdk_key: ENV.fetch('QUONFIG_BACKEND_SDK_KEY', nil),
      environment: ENV.fetch('QUONFIG_ENVIRONMENT', nil),
      datadir: ENV.fetch('QUONFIG_DIR', nil),
      enable_sse: true,
      enable_polling: true,
      poll_interval: 60,
      on_no_default: ON_NO_DEFAULT::RAISE,
      initialization_timeout_sec: 10,
      on_init_failure: ON_INITIALIZATION_FAILURE::RAISE,
      collect_max_paths: DEFAULT_MAX_PATHS,
      collect_sync_interval: nil,
      context_upload_mode: :periodic_example, # :periodic_example, :shapes_only, :none
      context_max_size: DEFAULT_MAX_EVAL_SUMMARIES,
      collect_evaluation_summaries: true,
      collect_max_evaluation_summaries: DEFAULT_MAX_EVAL_SUMMARIES,
      allow_telemetry_in_local_mode: false,
      global_context: {},
      logger_key: nil,
      logger: nil,
      enable_quonfig_user_context: false
    )
      @sdk_key = sdk_key
      @environment = environment
      @datadir = datadir
      @enable_sse = enable_sse
      @enable_polling = enable_polling
      @poll_interval = poll_interval
      @on_no_default = on_no_default
      @initialization_timeout_sec = initialization_timeout_sec
      @on_init_failure = on_init_failure

      @collect_max_paths = collect_max_paths
      @collect_sync_interval = collect_sync_interval
      @collect_evaluation_summaries = collect_evaluation_summaries
      @collect_max_evaluation_summaries = collect_max_evaluation_summaries
      @allow_telemetry_in_local_mode = allow_telemetry_in_local_mode
      @is_fork = false
      @global_context = global_context
      @logger_key = logger_key
      @logger = logger
      @enable_quonfig_user_context = enable_quonfig_user_context

      # defaults that may be overridden by context_upload_mode
      @collect_shapes = false
      @collect_max_shapes = 0
      @collect_example_contexts = false
      @collect_max_example_contexts = 0

      # URL resolution order (highest wins):
      #   1. Explicit kwargs (api_urls:, telemetry_url:)
      #   2. ENV['QUONFIG_DOMAIN'] -> derives all three
      #   3. Hardcoded DEFAULT_DOMAIN ('quonfig.com')
      domain = Quonfig::Options.domain

      @api_urls = Array(api_urls || Quonfig::Options.derive_api_urls(domain))
                  .map { |url| remove_trailing_slash(url) }

      @sse_api_urls = @api_urls.map { |url| Quonfig::Options.derive_stream_url(url) }
      @config_api_urls = @api_urls

      @telemetry_destination = telemetry_url || Quonfig::Options.derive_telemetry_url(domain)

      case context_upload_mode
      when :none
        # no context telemetry
      when :periodic_example
        @collect_example_contexts = true
        @collect_max_example_contexts = context_max_size
        @collect_shapes = true
        @collect_max_shapes = context_max_size
      when :shapes_only
        @collect_shapes = true
        @collect_max_shapes = context_max_size
      else
        raise "Unknown context_upload_mode #{context_upload_mode}. Please provide :periodic_example, :shapes_only, or :none."
      end
    end

    def telemetry_allowed?(option)
      option && (!local_only? || @allow_telemetry_in_local_mode)
    end

    def remove_trailing_slash(url)
      url.end_with?('/') ? url[0..-2] : url
    end
  end
end
