# frozen_string_literal: true

module Quonfig
  class ConfigClient
    LOG = Quonfig::InternalLogger.new(self)
    DEFAULT_CHECKPOINT_FREQ_SEC = 60
    STALE_CACHE_WARN_HOURS = 5

    def initialize(base_client, timeout)
      @base_client = base_client
      @options = base_client.options
      LOG.debug 'Initialize ConfigClient'
      @timeout = timeout

      @checkpoint_freq_secs = DEFAULT_CHECKPOINT_FREQ_SEC

      @config_loader = Quonfig::ConfigLoader.new(@base_client)
      @config_resolver = Quonfig::ConfigResolver.new(@base_client, @config_loader)

      @initialization_lock = Concurrent::CountDownLatch.new(1)

      if @options.local_only?
        finish_init!(:local_only, nil)
      elsif @options.datafile?
        load_json_file(@options.datafile)
      else
        load_checkpoint
        start_checkpointing_thread
        start_streaming
      end
    end

    def stop
      @sse_config_client&.close
    end

    def start_streaming
      Thread.new do
        # wait for the config loader to have a highwater mark before we connect the SSE
        loop do
          break if @config_loader.highwater_mark > 0

          sleep 0.1
        end

        stream_lock = Concurrent::ReadWriteLock.new
        @sse_config_client = Quonfig::SSEConfigClient.new(@options, @config_loader)

        @sse_config_client.start do |configs, _event, source|
          stream_lock.with_write_lock do
            load_configs(configs, source)
          end
        end
      end
    end

    def to_s
      @config_resolver.to_s
    end

    def resolver
      @config_resolver
    end

    def self.value_to_delta(key, config_value, namespace = nil)
      PrefabProto::Config.new(key: [namespace, key].compact.join(':'),
                              rows: [PrefabProto::ConfigRow.new(value: config_value)])
    end

    def get(key, default = NO_DEFAULT_PROVIDED, properties = NO_DEFAULT_PROVIDED)
      context = @config_resolver.make_context(properties)

      if !context.blank? && @base_client.example_contexts_aggregator
        @base_client.example_contexts_aggregator.record(context)
      end

      evaluation = _get(key, properties)

      @base_client.context_shape_aggregator&.push(context)

      if evaluation
        evaluation.report_and_return(@base_client.evaluation_summary_aggregator)
      else
        handle_default(key, default)
      end
    end

    def initialized?
      @initialization_lock.count <= 0
    end

    private

    def raw(key)
      @config_resolver.raw(key)
    end

    def handle_default(key, default)
      return default if default != NO_DEFAULT_PROVIDED

      raise Quonfig::Errors::MissingDefaultError, key if @options.on_no_default == Quonfig::Options::ON_NO_DEFAULT::RAISE

      nil
    end

    def _get(key, properties)
      # wait timeout sec for the initialization to be complete
      success = @initialization_lock.wait(@options.initialization_timeout_sec)
      if !success
        unless @options.on_init_failure == Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN
          raise Quonfig::Errors::InitializationTimeoutError.new(@options.initialization_timeout_sec, key)
        end

        LOG.warn("Couldn't Initialize In #{@options.initialization_timeout_sec}. Key #{key}. Returning what we have")
      end

      @config_resolver.get key, properties
    end

    def load_checkpoint
      success = load_source_checkpoint(:start_at_id => @config_loader.highwater_mark)
      return if success

      success = load_cache
      return if success

      LOG.warn 'No success loading checkpoints'
    end

    def load_source_checkpoint(start_at_id: 0)
      @options.config_sources.each do |source|
        conn = Quonfig::CachingHttpConnection.new("#{source}/api/v2/configs/#{start_at_id}", @base_client.sdk_key)
        result = load_url(conn, :remote_api)
        return true if result
      end

      return false
    end

    def load_url(conn, source)
      resp = conn.get('')
      if resp.status == 200
        if resp.body.nil? || resp.body.empty?
          LOG.warn "Checkpoint #{source} [#{conn.uri}] failed to load. Response body is empty"
          return false
        end

        configs = PrefabProto::Configs.decode(resp.body)
        load_configs(configs, source)
        cache_configs(configs)
        true
      else
        LOG.info "Checkpoint #{source} [#{conn.uri}] failed to load. Response #{resp.status}"
        false
      end
    rescue Faraday::ConnectionFailed => e
      if !initialized?
        LOG.warn "Connection Fail loading #{source} [#{conn.uri}] checkpoint."
      else
        LOG.debug "Connection Fail loading #{source} [#{conn.uri}] checkpoint."
      end
      false
    rescue StandardError => e
      LOG.warn "Unexpected #{source} [#{conn.uri}] problem loading checkpoint #{e} #{conn}"
      LOG.debug e.backtrace
      false
    end

    def load_configs(configs, source)
      project_id = configs.config_service_pointer.project_id
      project_env_id = configs.config_service_pointer.project_env_id
      @config_resolver.project_env_id = project_env_id
      starting_highwater_mark = @config_loader.highwater_mark

      default_contexts = configs.default_context&.contexts&.map do |context|
        [
          context.type,
          context.values.keys.map do |k|
            [k, Quonfig::ConfigValueUnwrapper.new(context.values[k], @config_resolver).unwrap]
          end.to_h
        ]
      end.to_h

      Quonfig::Context.default_context = default_contexts || {}

      configs.configs.each do |config|
        @config_loader.set(config, source)
      end
      if @config_loader.highwater_mark > starting_highwater_mark
        LOG.debug("Found new checkpoint with highwater id #{@config_loader.highwater_mark} from #{source} in project #{project_id} environment: #{project_env_id} and namespace: '#{@namespace}'")
      else
        LOG.debug("Checkpoint with highwater id #{@config_loader.highwater_mark} from #{source}. No changes.")
      end
      @config_resolver.update
      finish_init!(source, project_id)
    end

    def cache_path
      return @cache_path unless @cache_path.nil?
      @cache_path ||= calc_cache_path
      FileUtils.mkdir_p(File.dirname(@cache_path))
      @cache_path
    end

    def calc_cache_path
      file_name = "prefab.cache.#{@base_client.options.sdk_key_id}.json"
      dir = ENV.fetch('XDG_CACHE_HOME', File.join(Dir.home, '.cache'))
      File.join(dir, file_name)
    end

    def cache_configs(configs)
      return unless @options.use_local_cache && !@options.is_fork
      File.open(cache_path, "w") do |f|
        f.flock(File::LOCK_EX)
        f.write(PrefabProto::Configs.encode_json(configs))
      end
      LOG.debug "Cached configs to #{cache_path}"
    rescue => e
      LOG.debug "Failed to cache configs to #{cache_path} #{e}"
    end

    def load_cache
      return false unless @options.use_local_cache
      File.open(cache_path) do |f|
        f.flock(File::LOCK_SH)
        content = f.read
        if content.nil? || content.empty?
          LOG.warn "Failed to read cached configs at #{cache_path}. File is empty"
          return false
        end

        configs = PrefabProto::Configs.decode_json(content)
        load_configs(configs, :cache)

        hours_old = ((Time.now - File.mtime(f)) / 60 / 60).round(2)
        if hours_old > STALE_CACHE_WARN_HOURS
          LOG.info "Stale Cache Load: #{hours_old} hours old"
        end
        true
      end
    rescue => e
      LOG.debug "Failed to read cached configs at #{cache_path}. #{e}"
      false
    end

    def load_json_file(file)
      File.open(file) do |f|
        f.flock(File::LOCK_SH)
        content = f.read
        if content.nil? || content.empty?
          LOG.warn "Failed to read datafile at #{file}. File is empty"
          return false
        end

        configs = PrefabProto::Configs.decode_json(content)
        load_configs(configs, :datafile)
      end
    end

    # A thread that checks for a checkpoint
    def start_checkpointing_thread
      Thread.new do
        loop do
          started_at = Time.now
          delta = @checkpoint_freq_secs - (Time.now - started_at)
          sleep(delta) if delta > 0

          load_checkpoint
        rescue StandardError => e
          LOG.debug "Issue Checkpointing #{e.message}"
        end
      end
    end

    def finish_init!(source, project_id)
      return if initialized?

      LOG.debug "Unlocked Config via #{source}"
      @initialization_lock.count_down

      presenter = Quonfig::ConfigClientPresenter.new(
        size: @config_resolver.local_store.size,
        source: source,
        project_id: project_id,
        project_env_id: @config_resolver.project_env_id,
        sdk_key_id: @base_client.options.sdk_key_id
      )
      LOG.info presenter.to_s
      LOG.debug to_s
    end
  end
end
