# frozen_string_literal: true

module Quonfig
  # This class contains all the options that can be passed to the Prefab client.
  class Options
    attr_reader :sdk_key
    attr_reader :namespace
    attr_reader :sources
    attr_reader :sse_sources
    attr_reader :telemetry_destination
    attr_reader :config_sources
    attr_reader :on_no_default
    attr_reader :initialization_timeout_sec
    attr_reader :on_init_failure
    attr_reader :collect_sync_interval
    attr_reader :use_local_cache
    attr_reader :datafile
    attr_reader :global_context
    attr_accessor :is_fork
    attr_reader :symbolize_json_names
    attr_reader :logger_key

    module ON_INITIALIZATION_FAILURE
      RAISE = :raise
      RETURN = :return
    end

    module ON_NO_DEFAULT
      RAISE = :raise
      RETURN_NIL = :return_nil
    end

    module DATASOURCES
      ALL = :all
      LOCAL_ONLY = :local_only
    end

    DEFAULT_MAX_PATHS = 1_000
    DEFAULT_MAX_KEYS = 100_000
    DEFAULT_MAX_EXAMPLE_CONTEXTS = 100_000
    DEFAULT_MAX_EVAL_SUMMARIES = 100_000

    DEFAULT_SOURCES = [
      "https://primary.quonfig.com",
      "https://secondary.quonfig.com",
    ].freeze

    DEFAULT_TELEMETRY_URL = "https://telemetry.quonfig.com"

    private def init(
      sources: nil,
      sdk_key: ENV['QUONFIG_BACKEND_SDK_KEY'] || ENV['QUONFIG_BACKEND_SDK_KEY'],
      namespace: '',
      quonfig_api_url: nil,
      on_no_default: ON_NO_DEFAULT::RAISE, # options :raise, :warn_and_return_nil,
      initialization_timeout_sec: 10, # how long to wait before on_init_failure
      on_init_failure: ON_INITIALIZATION_FAILURE::RAISE,
      prefab_datasources: (ENV['QUONFIG_DATASOURCES'] || ENV['QUONFIG_DATASOURCES']) == 'LOCAL_ONLY' ? DATASOURCES::LOCAL_ONLY : DATASOURCES::ALL,
      collect_logger_counts: true,
      collect_max_paths: DEFAULT_MAX_PATHS,
      collect_sync_interval: nil,
      context_upload_mode: :periodic_example, # :periodic_example, :shape_only, :none
      context_max_size: DEFAULT_MAX_EVAL_SUMMARIES,
      collect_evaluation_summaries: true,
      collect_max_evaluation_summaries: DEFAULT_MAX_EVAL_SUMMARIES,
      allow_telemetry_in_local_mode: false,
      datafile: ENV['QUONFIG_DATAFILE'] || ENV['QUONFIG_DIR'],
      x_datafile: nil, # DEPRECATED in favor of `datafile`
      x_use_local_cache: false,
      symbolize_json_names: false,
      global_context: {},
      logger_key: 'log-levels.default'
    )
      @sdk_key = sdk_key
      @namespace = namespace
      @on_no_default = on_no_default
      @initialization_timeout_sec = initialization_timeout_sec
      @on_init_failure = on_init_failure
      @prefab_datasources = prefab_datasources

      @datafile = datafile || x_datafile

      if !x_datafile.nil?
        warn '[DEPRECATION] x_datafile is deprecated. Please provide `datafile` instead'
      end

      @collect_logger_counts = collect_logger_counts
      @collect_max_paths = collect_max_paths
      @collect_sync_interval = collect_sync_interval
      @collect_evaluation_summaries = collect_evaluation_summaries
      @collect_max_evaluation_summaries = collect_max_evaluation_summaries
      @allow_telemetry_in_local_mode = allow_telemetry_in_local_mode
      @use_local_cache = x_use_local_cache
      @is_fork = false
      @global_context = global_context
      @symbolize_json_names = symbolize_json_names
      @logger_key = logger_key

      # defaults that may be overridden by context_upload_mode
      @collect_shapes = false
      @collect_max_shapes = 0
      @collect_example_contexts = false
      @collect_max_example_contexts = 0

      if ENV['QUONFIG_SOURCES'] && ENV['QUONFIG_SOURCES'].length > 0
        sources = ENV['QUONFIG_SOURCES']
      end

      @sources = Array(sources || DEFAULT_SOURCES).map {|source| remove_trailing_slash(source) }

      @sse_sources = @sources
      @config_sources = @sources

      @telemetry_destination = ENV['QUONFIG_TELEMETRY_URL'] || DEFAULT_TELEMETRY_URL

      if quonfig_api_url
        warn '[DEPRECATION] quonfig_api_url is deprecated. Please provide `sources` if you need to override the default sources'
      end

      case context_upload_mode
      when :none
        # do nothing
      when :periodic_example
        @collect_example_contexts = true
        @collect_max_example_contexts = context_max_size
        @collect_shapes = true
        @collect_max_shapes = context_max_size
      when :shape_only
        @collect_shapes = true
        @collect_max_shapes = context_max_size
      else
        raise "Unknown context_upload_mode #{context_upload_mode}. Please provide :periodic_example, :shape_only, or :none."
      end
    end

    def initialize(options = {})
      init(**options)
    end

    def local_only?
      @prefab_datasources == DATASOURCES::LOCAL_ONLY
    end

    def datafile?
      !@datafile.nil?
    end

    def collect_max_paths
      return 0 unless telemetry_allowed?(@collect_logger_counts)

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
      @sdk_key&.split("-")&.first
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
  end
end
