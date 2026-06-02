# frozen_string_literal: true

require 'uri'

module Quonfig
  # Options passed to Quonfig::Client at construction time.
  class Options
    attr_reader :sdk_key, :environment, :api_urls, :sse_api_urls, :telemetry_destination, :config_api_urls,
                :on_no_default, :init_timeout_ms, :on_init_failure, :collect_sync_interval, :datadir, :enable_sse, :fallback_poll_enabled, :fallback_poll_interval_ms, :global_context, :logger_key, :logger, :enable_quonfig_user_context,
                :data_dir_auto_reload, :data_dir_auto_reload_debounce_ms
    attr_accessor :is_fork

    # Default fallback poll interval, in milliseconds. The SDK polls api-delivery
    # at this cadence only when SSE is unavailable for >= 2x this value.
    DEFAULT_FALLBACK_POLL_INTERVAL_MS = 60_000

    # Default initialization timeout, in milliseconds. The SDK waits up to this
    # long for the initial config fetch before failing per :on_init_failure.
    DEFAULT_INIT_TIMEOUT_MS = 10_000

    # Deprecated alias for #fallback_poll_enabled. Will be removed in a future
    # minor release.
    def enable_polling
      @fallback_poll_enabled
    end

    # Deprecated alias for #fallback_poll_interval_ms, in seconds. Reads back the
    # interval in the legacy unit so existing callers (e.g. internal code that
    # `sleep`s on this value) keep working. Will be removed in a future minor
    # release.
    def poll_interval
      @fallback_poll_interval_ms / 1000.0
    end

    # Deprecated alias for #init_timeout_ms, in seconds. Reads back the timeout
    # in the legacy unit so existing callers (e.g. internal code that passes
    # this to Timeout.timeout) keep working. Will be removed in a future minor
    # release.
    def initialization_timeout_sec
      ms = @init_timeout_ms.to_f / 1000.0
      ms == ms.to_i ? ms.to_i : ms
    end

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

    # @!method initialize(options = {})
    #   @option options [Boolean] :data_dir_auto_reload (false)
    #     Datadir mode only. When +true+, the SDK watches the workspace
    #     directory and re-reads the envelope whenever files inside it
    #     change. Parse-then-swap: a failed parse keeps the previous
    #     envelope. Default debounce window is 200 ms; tune via
    #     +:data_dir_auto_reload_debounce_ms+. Listen-registration failure
    #     (read-only fs, missing native backend) is logged and the SDK
    #     continues serving the envelope captured at init.
    #
    #     On Ruby 3.1+ the SDK's +Process._fork+ hook tears the watcher
    #     down in the parent before fork and rebuilds it in each child;
    #     no customer wiring is required for Puma cluster / Unicorn /
    #     Sidekiq / Resque. See README "Fork safety".
    #   @option options [Integer] :data_dir_auto_reload_debounce_ms (200)
    #     Debounce window in milliseconds. Filesystem events arriving
    #     inside the window are coalesced into a single re-read. Ignored
    #     when +:data_dir_auto_reload+ is +false+.
    def init(
      api_urls: nil,
      telemetry_url: nil,
      sdk_key: ENV.fetch('QUONFIG_BACKEND_SDK_KEY', nil),
      environment: ENV.fetch('QUONFIG_ENVIRONMENT', nil),
      datadir: ENV.fetch('QUONFIG_DIR', nil),
      enable_sse: true,
      fallback_poll_enabled: nil,
      fallback_poll_interval_ms: nil,
      enable_polling: nil,
      poll_interval: nil,
      on_no_default: ON_NO_DEFAULT::RAISE,
      init_timeout_ms: nil,
      initialization_timeout_sec: nil,
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
      # Tri-state (nil = unset). Default ON, gated only by the presence of
      # ~/.quonfig/tokens.json; see Client#build_initial_global_context.
      enable_quonfig_user_context: nil,
      data_dir_auto_reload: false,
      data_dir_auto_reload_debounce_ms: 200
    )
      @sdk_key = sdk_key
      @environment = environment
      @datadir = datadir
      @enable_sse = enable_sse
      # qfg-thsn: canonical names are fallback_poll_enabled and
      # fallback_poll_interval_ms (matches sdk-node / sdk-python / sdk-java).
      # The legacy enable_polling / poll_interval (seconds) kwargs are kept
      # as deprecated aliases for one minor cycle. The canonical kwarg wins
      # if both are passed; otherwise the legacy value is forwarded (and the
      # seconds-based interval is multiplied *1000 transparently).
      @fallback_poll_enabled = if !fallback_poll_enabled.nil?
                                 fallback_poll_enabled
                               elsif !enable_polling.nil?
                                 enable_polling
                               else
                                 true
                               end
      @fallback_poll_interval_ms = if !fallback_poll_interval_ms.nil?
                                     fallback_poll_interval_ms
                                   elsif !poll_interval.nil?
                                     poll_interval * 1000
                                   else
                                     DEFAULT_FALLBACK_POLL_INTERVAL_MS
                                   end
      @on_no_default = on_no_default
      # qfg-39za: canonical name is init_timeout_ms. The legacy
      # initialization_timeout_sec (seconds) kwarg is kept as a deprecated
      # alias for one minor cycle. The canonical kwarg wins if both are
      # passed; otherwise the legacy value is forwarded (and the seconds-based
      # timeout is multiplied *1000 transparently).
      @init_timeout_ms = if !init_timeout_ms.nil?
                           init_timeout_ms
                         elsif !initialization_timeout_sec.nil?
                           (initialization_timeout_sec * 1000).to_i
                         else
                           DEFAULT_INIT_TIMEOUT_MS
                         end
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
      @data_dir_auto_reload = data_dir_auto_reload
      @data_dir_auto_reload_debounce_ms = data_dir_auto_reload_debounce_ms

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
