# frozen_string_literal: true

require 'uri'

module Quonfig
  # Options passed to Quonfig::Client at construction time.
  class Options
    attr_reader :sdk_key
    attr_reader :environment
    attr_reader :api_urls
    attr_reader :sse_api_urls
    attr_reader :telemetry_destination
    attr_reader :config_api_urls
    attr_reader :on_no_default
    attr_reader :initialization_timeout_sec
    attr_reader :on_init_failure
    attr_reader :collect_sync_interval
    attr_reader :datadir
    attr_reader :enable_sse
    attr_reader :enable_polling
    attr_reader :poll_interval
    attr_reader :global_context
    attr_reader :logger_key
    attr_reader :enable_quonfig_user_context
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

    DEFAULT_API_URLS = [
      'https://primary.quonfig.com',
    ].freeze

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

    private def init(
      api_urls: nil,
      sdk_key: ENV['QUONFIG_BACKEND_SDK_KEY'],
      environment: ENV['QUONFIG_ENVIRONMENT'],
      datadir: ENV['QUONFIG_DIR'],
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
      @enable_quonfig_user_context = enable_quonfig_user_context

      # defaults that may be overridden by context_upload_mode
      @collect_shapes = false
      @collect_max_shapes = 0
      @collect_example_contexts = false
      @collect_max_example_contexts = 0

      if ENV['QUONFIG_API_URLS'] && ENV['QUONFIG_API_URLS'].length > 0
        api_urls = ENV['QUONFIG_API_URLS']
      end

      @api_urls = Array(api_urls || DEFAULT_API_URLS).map { |url| remove_trailing_slash(url) }

      @sse_api_urls = @api_urls.map { |url| Quonfig::Options.derive_stream_url(url) }
      @config_api_urls = @api_urls

      @telemetry_destination = ENV['QUONFIG_TELEMETRY_URL'] || derive_telemetry_destination(@api_urls)

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

    def telemetry_allowed?(option)
      option && (!local_only? || @allow_telemetry_in_local_mode)
    end

    def remove_trailing_slash(url)
      url.end_with?('/') ? url[0..-2] : url
    end

    # Derive a telemetry URL from the configured api_urls by swapping the
    # primary/secondary host prefix for `telemetry` on a *.quonfig.com host.
    # Falls back to https://telemetry.quonfig.com if no URL matches.
    def derive_telemetry_destination(api_urls)
      api_urls.each do |api_url|
        match = api_url.match(%r{\Ahttps?://(?:primary|secondary)\.([^/]*quonfig\.com)}i)
        return "https://telemetry.#{match[1]}" if match
      end
      'https://telemetry.quonfig.com'
    end
  end
end
