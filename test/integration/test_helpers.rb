# frozen_string_literal: true

require 'json'
require 'quonfig'

# Integration-test environment — the generated tests read these the same way
# the SDK does at runtime. Mirrors sdk-node/test/integration/setup.ts and
# sdk-go/internal/fixtures/test_helpers_test.go so behavior stays consistent
# across SDKs.
ENV['PREFAB_INTEGRATION_TEST_ENCRYPTION_KEY'] =
  'c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221'
ENV['IS_A_NUMBER'] = '1234'
ENV['NOT_A_NUMBER'] = 'not_a_number'
ENV.delete('MISSING_ENV_VAR')

# Shared fixture loader + resolver factory for the generated integration
# tests in sdk-ruby/test/integration/test_*.rb (qfg-dk6.23/.24). The evaluator
# wired up here still delegates to Quonfig::CriteriaEvaluator — once
# qfg-dk6.10 ports the criterion operators to the JSON Criterion type,
# generated tests will resolve end-to-end. Until then build_store simply
# parses the JSON fixtures into the ConfigStore.
module IntegrationTestHelpers
  DATA_DIR = File.expand_path(
    '../../../integration-test-data/data/integration-tests',
    __dir__
  )
  ENV_ID = 'Production'
  CONFIG_SUBDIRS = %w[configs feature-flags segments log-levels schemas].freeze

  def self.data_dir
    DATA_DIR
  end

  # fixture_name matches the generator's YAML suite name (e.g. 'get',
  # 'enabled'). Every suite shares the same config corpus — mirrors
  # sdk-node/sdk-go, which also build a single store for the whole run —
  # so the name is advisory. Accepting it keeps the call shape the task
  # spec asks for and leaves room for per-suite overlays later.
  def self.build_store(_fixture_name = nil)
    unless Dir.exist?(DATA_DIR)
      raise "[integration tests] fixtures not found at #{DATA_DIR} — " \
            'clone quonfig/integration-test-data as a sibling of sdk-ruby.'
    end

    store = Quonfig::ConfigStore.new
    CONFIG_SUBDIRS.each do |subdir|
      dir = File.join(DATA_DIR, subdir)
      next unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.json')).each do |path|
        raw = JSON.parse(File.read(path))
        cfg = to_config_response(raw)
        key = cfg[:key]
        next if key.nil? || key.empty?

        store.set(key, cfg)
      end
    end
    self.last_store = store
    store
  end

  def self.build_resolver(store)
    evaluator = Quonfig::Evaluator.new(store, env_id: ENV_ID)
    Quonfig::Resolver.new(store, evaluator)
  end

  # Resolve +key+ against +context+ and assert the unwrapped value (and,
  # when present, its reported value_type) match. Generated tests call
  # this for the "no default, no enabled" path. With the generator now
  # threading input.default through assert_get_with_default and routing
  # function: enabled cases through assert_enabled, this helper can stay
  # strict: missing keys still raise, non-bool actual stays non-bool.
  # Nil-expected cases (e.g. "get returns nil if value not found" with
  # on_no_default: 2) catch the resolver's MissingDefaultError and return nil.
  def self.assert_resolved(resolver, key, context, expected_value, expected_type = nil)
    ctx = context.is_a?(Quonfig::Context) ? context : Quonfig::Context.new(context || {})
    result =
      begin
        resolver.get(key, ctx)
      rescue Quonfig::Errors::MissingDefaultError
        nil
      end
    return expected_value if result.nil? && expected_value.nil?

    actual = if result.nil?
               nil
             elsif result.respond_to?(:unwrapped_value)
               result.unwrapped_value
             elsif result.respond_to?(:value)
               v = result.value
               v.respond_to?(:string) ? v.string : v
             else
               result
             end

    unless actual == expected_value
      raise Minitest::Assertion,
            "#{key}: expected #{expected_value.inspect} (#{expected_type}), got #{actual.inspect}"
    end

    if expected_type && result.respond_to?(:value_type)
      unless result.value_type.to_s == expected_type.to_s
        raise Minitest::Assertion,
              "#{key}: expected type #{expected_type}, got #{result.value_type}"
      end
    end
    actual
  end

  # function: enabled semantics — Quonfig::Client#enabled? returns the
  # bool value if the resolved value is a boolean, false otherwise.
  # The generator routes function: enabled cases through this helper so
  # the bool-coercion lives here, not inferred from the expected literal.
  def self.assert_enabled(resolver, key, context, expected_bool)
    ctx = context.is_a?(Quonfig::Context) ? context : Quonfig::Context.new(context || {})
    actual =
      begin
        result = resolver.get(key, ctx)
        if result.nil?
          false
        else
          v = result.respond_to?(:unwrapped_value) ? result.unwrapped_value : result
          (v == true || v == 'true') ? true : false
        end
      rescue Quonfig::Errors::MissingDefaultError
        false
      end
    unless actual == expected_bool
      raise Minitest::Assertion,
            "enabled?(#{key}): expected #{expected_bool.inspect}, got #{actual.inspect}"
    end
    actual
  end

  # input.default — thread the YAML default through the SDK's public
  # get(key, default) API. Build a Client over the same store the
  # resolver uses; that way we observe what the SDK actually returns
  # (default kicks in for missing keys, found-key wins over default).
  def self.assert_get_with_default(store, key, context, default_value, expected_value)
    # Build with environment: ENV_ID so config rules evaluate against the
    # 'Production' environment (matching what build_resolver does). Without
    # this the Client falls back to default rules.
    client = Quonfig::Client.new(store: store, environment: ENV_ID)
    ctx_arg =
      if context.nil? || (context.respond_to?(:empty?) && context.empty?)
        Quonfig::NO_DEFAULT_PROVIDED
      elsif context.is_a?(Quonfig::Context)
        context
      else
        Quonfig::Context.new(context)
      end
    actual = client.get(key, default_value, ctx_arg)
    unless actual == expected_value
      raise Minitest::Assertion,
            "#{key}: expected #{expected_value.inspect} (default=#{default_value.inspect}), got #{actual.inspect}"
    end
    actual
  end

  # Build a real Quonfig::Client whose initial fetch is intentionally slow
  # (an unreachable api_url + tiny init timeout) and assert that
  # Client#get raises Quonfig::Errors::InitializationTimeoutError.
  def self.assert_initialization_timeout_error(key, timeout_sec, api_url, on_init_failure)
    on_init = on_init_failure.to_s.sub(/\A:/, '').to_sym
    api_urls = api_url && !api_url.empty? ? [api_url] : ['https://127.0.0.1:1']
    client =
      begin
        Quonfig::Client.new(
          sdk_key: 'test-unused',
          api_urls: api_urls,
          initialization_timeout_sec: timeout_sec,
          on_init_failure: on_init,
          enable_sse: false,
          enable_polling: false
        )
      rescue Quonfig::Errors::InitializationTimeoutError
        return # construction itself raised — that's the expected outcome
      end
    raise Minitest::Assertion,
          'expected Quonfig::Errors::InitializationTimeoutError to raise on get' \
      unless on_init == :raise

    begin
      client.get(key)
      raise Minitest::Assertion, "expected get(#{key}) to raise InitializationTimeoutError but it returned"
    rescue Quonfig::Errors::InitializationTimeoutError
      # success
    ensure
      client.respond_to?(:close) && client.close
      $logs = nil if defined?($logs)
    end
  end

  # Generic raise path through a real-client construction (e.g. on_init_failure
  # :return + missing_default on get_or_raise — init returns zero value,
  # then get_or_raise still raises MissingDefault). The function arg picks
  # the call shape: 'get_or_raise' uses get_or_raise(key); anything else
  # falls back to client.get(key).
  #
  # The Client logs a warning when init returns the zero value (the typical
  # on_init_failure: :return path). Drain $logs (if it exists from
  # CommonHelpers) so the test's teardown doesn't trip on it — that's the
  # whole point of the case.
  def self.assert_client_construction_raises(key, timeout_sec, api_url, on_init_failure, fn, err_class)
    on_init = on_init_failure.to_s.sub(/\A:/, '').to_sym
    api_urls = api_url && !api_url.empty? ? [api_url] : ['https://127.0.0.1:1']
    client = Quonfig::Client.new(
      sdk_key: 'test-unused',
      api_urls: api_urls,
      initialization_timeout_sec: timeout_sec,
      on_init_failure: on_init,
      enable_sse: false,
      enable_polling: false
    )
    begin
      if fn == 'get_or_raise' && client.respond_to?(:get_or_raise)
        client.get_or_raise(key)
      else
        # No public get_or_raise: call .get with no default and the SDK's
        # internal NO_DEFAULT_PROVIDED forces the missing-default raise.
        client.get(key)
      end
      raise Minitest::Assertion, "expected #{err_class} to raise but call returned"
    rescue err_class
      # success
    ensure
      client.respond_to?(:close) && client.close
      # Acknowledge the init-warning log so common_helpers' teardown won't
      # blow up. The warning IS the thing we asked for via :return policy.
      $logs = nil if defined?($logs)
    end
  end

  # Happy path through a real-client construction (rare; mostly here for
  # symmetry — the YAML init-timeout cases are all raise-path).
  def self.assert_client_construction_value(key, timeout_sec, api_url, on_init_failure, _fn, expected_value)
    on_init = on_init_failure.to_s.sub(/\A:/, '').to_sym
    api_urls = api_url && !api_url.empty? ? [api_url] : ['https://127.0.0.1:1']
    client = Quonfig::Client.new(
      sdk_key: 'test-unused',
      api_urls: api_urls,
      initialization_timeout_sec: timeout_sec,
      on_init_failure: on_init,
      enable_sse: false,
      enable_polling: false
    )
    actual = client.get(key)
    unless actual == expected_value
      raise Minitest::Assertion,
            "#{key}: expected #{expected_value.inspect}, got #{actual.inspect}"
    end
    client.respond_to?(:close) && client.close
    actual
  end

  # Temporarily set env vars for the duration of the block and restore the
  # originals (including absence) on exit — even if the block raises.
  def self.with_env(vars_hash)
    originals = {}
    vars_hash.each do |k, v|
      originals[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    originals.each do |k, v|
      if v.nil?
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
  end

  # ----------------------------------------------------------------------
  # Aggregator helpers for the post.yaml + telemetry.yaml generated suites.
  # ----------------------------------------------------------------------
  #
  # The shared YAML in integration-test-data/tests/eval/{post,telemetry}.yaml
  # describes telemetry payloads in language-neutral terms — `aggregator:
  # context_shape | evaluation_summary | example_contexts` plus a `data`
  # block of inputs and an `expected_data` block of the would-be POST body.
  # The Ruby generator emits one method per case calling these three
  # helpers. They wire the YAML inputs through the real aggregator classes
  # (Quonfig::Telemetry::*) and translate the aggregator's drain_event
  # output into the YAML's snake_case schema for assertion.
  #
  # Recent build_store call stashes the Quonfig::ConfigStore on the module
  # so eval-summary cases can resolve real values for each key.
  class << self
    attr_accessor :last_store
    # Side-channel populated by record_one_eval whenever we redact a
    # confidential value before recording it on the aggregator. Keyed by
    # config_key → { unwrapped:, value_type: }. evaluation_summary_post
    # consults it so the YAML's `value` / `value_type` fields can still
    # assert the runtime resolved value while `selected_value` carries
    # the wire-redacted form.
    attr_accessor :last_unwrapped_overrides
  end

  # Construct an aggregator. +kind+ is one of :context_shape,
  # :evaluation_summary, :example_contexts (string or symbol). +overrides+
  # mirrors the YAML `client_overrides` block; the only options that
  # affect aggregator output today are `collect_evaluation_summaries`
  # (false → eval-summary aggregator created with max_keys=0 so it noops)
  # and `context_upload_mode` ("shape_only" / "none" → example-contexts
  # aggregator created with max=0; ":none" / ":shape_only" come through
  # as Ruby-symbol strings via js-yaml, which is why we strip the leading
  # colon defensively).
  def self.build_aggregator(kind, overrides = {})
    overrides = (overrides || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    case normalize_kind(kind)
    when :context_shape
      max = aggregator_max_for(overrides, :context_shape)
      Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: max)
    when :evaluation_summary
      collect = overrides.fetch('collect_evaluation_summaries', true)
      max = collect ? 100_000 : 0
      Quonfig::Telemetry::EvaluationSummariesAggregator.new(max_keys: max)
    when :example_contexts
      max = aggregator_max_for(overrides, :example_contexts)
      Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: max)
    else
      raise ArgumentError, "Unknown aggregator kind: #{kind.inspect}"
    end
  end

  # Feed +data+ through +aggregator+ for the given +kind+. Each kind has
  # its own input shape (see post.yaml / telemetry.yaml):
  # - :context_shape   → +data+ is a Hash of named contexts, OR an Array
  #                      of such hashes (multi-record case).
  # - :evaluation_summary
  #                    → +data+ is { 'keys' => [...], 'keys_without_context'
  #                      => [...] }. Each key is resolved against
  #                      +contexts+ (or empty contexts for the second
  #                      list), then the EvalResult is recorded.
  # - :example_contexts → same as :context_shape but recorded into the
  #                      example aggregator.
  def self.feed_aggregator(aggregator, kind, data, contexts: {})
    case normalize_kind(kind)
    when :context_shape
      each_context_record(data) { |rec| aggregator.push(rec) }
    when :example_contexts
      each_context_record(data) { |rec| aggregator.record(Quonfig::Context.new(rec)) }
    when :evaluation_summary
      record_eval_keys(aggregator, data, contexts)
    else
      raise ArgumentError, "Unknown aggregator kind: #{kind.inspect}"
    end
  end

  # Drain the aggregator and assert its would-be POST body matches
  # +expected_data+. +endpoint+ is captured from YAML for diagnostics
  # (the Ruby helpers don't actually POST anything — the aggregator's
  # drain_event payload is what the reporter would ship). +expected_data+
  # is YAML-shaped (snake_case `field_types` etc.); we project the
  # aggregator's drain output into that shape so the comparison is
  # apples-to-apples.
  def self.assert_aggregator_post(aggregator, kind, expected_data, endpoint:)
    actual = build_actual_post(aggregator, kind)

    if expected_data.nil?
      unless actual.nil?
        raise Minitest::Assertion,
              "[#{endpoint}] expected no telemetry POST but aggregator produced #{actual.inspect}"
      end
      return
    end

    expected_normalized, actual_normalized = align_for_comparison(expected_data, actual, kind)
    actual_normalized = scrub_optional_fields(actual_normalized, expected_normalized, kind)

    unless actual_normalized == expected_normalized
      raise Minitest::Assertion,
            "[#{endpoint}] aggregator POST mismatch\n  expected: #{expected_normalized.inspect}\n  actual:   #{actual_normalized.inspect}"
    end
  end

  # Normalize ordering on both sides for comparison. Telemetry payloads
  # are conceptually unordered sets — different SDKs (and different runs
  # within a single SDK if you swap a Hash for a different impl) emit
  # entries in different orders. Sort by a stable key so the comparison
  # is set-equality. Keeps assertion errors readable: both sides print in
  # the same canonical order.
  def self.align_for_comparison(expected, actual, kind)
    case normalize_kind(kind)
    when :evaluation_summary
      sort_key = ->(row) { [row['key'].to_s, (row.dig('summary', 'conditional_value_index') || 0)] }
      [expected.is_a?(Array) ? expected.sort_by(&sort_key) : expected,
       actual.is_a?(Array)   ? actual.sort_by(&sort_key)   : actual]
    when :context_shape
      sort_key = ->(row) { row['name'].to_s }
      [expected.is_a?(Array) ? expected.sort_by(&sort_key) : expected,
       actual.is_a?(Array)   ? actual.sort_by(&sort_key)   : actual]
    else
      [expected, actual]
    end
  end
  private_class_method :align_for_comparison

  # Drop fields from +actual+ that the YAML's +expected+ doesn't assert.
  # Today only `selected_value` in eval-summary rows is opt-in (some YAML
  # cases verify the proto-style wrapper, most don't). Index pairwise so
  # the per-row decision lines up.
  def self.scrub_optional_fields(actual, expected, kind)
    return actual unless normalize_kind(kind) == :evaluation_summary
    return actual unless actual.is_a?(Array) && expected.is_a?(Array)

    actual.each_with_index.map do |row, idx|
      exp_row = expected[idx]
      next row unless row.is_a?(Hash) && exp_row.is_a?(Hash)
      next row if exp_row.key?('selected_value')

      row.reject { |k, _| k == 'selected_value' }
    end
  end
  private_class_method :scrub_optional_fields

  # --- aggregator-helper internals ---

  def self.normalize_kind(kind)
    str = kind.to_s
    str = str.sub(/\A:/, '') # ":shape_only" → "shape_only" if a stray symbol-string sneaks in
    case str
    when 'context_shape'      then :context_shape
    when 'evaluation_summary' then :evaluation_summary
    when 'example_contexts'   then :example_contexts
    else raise ArgumentError, "Unknown aggregator kind: #{kind.inspect}"
    end
  end
  private_class_method :normalize_kind

  # Strip a leading `:` so a Ruby-symbol-style YAML scalar (":shape_only"
  # → ":shape_only" string when js-yaml serializes it) compares cleanly.
  def self.strip_symbol(v)
    v.is_a?(String) ? v.sub(/\A:/, '') : v.to_s
  end
  private_class_method :strip_symbol

  def self.aggregator_max_for(overrides, agg_kind)
    mode = strip_symbol(overrides['context_upload_mode']) if overrides.key?('context_upload_mode')
    return 0 if mode == 'none'

    case agg_kind
    when :context_shape    then 100_000
    when :example_contexts then mode == 'shape_only' ? 0 : 100_000
    end
  end
  private_class_method :aggregator_max_for

  def self.each_context_record(data)
    return if data.nil?

    if data.is_a?(Array)
      data.each { |row| yield row if row.is_a?(Hash) && !row.empty? }
    elsif data.is_a?(Hash)
      yield data unless data.empty?
    end
  end
  private_class_method :each_context_record

  def self.record_eval_keys(aggregator, data, contexts)
    return unless data.is_a?(Hash)

    keys = data['keys'] || data[:keys] || []
    keys_no_ctx = data['keys_without_context'] || data[:keys_without_context] || []
    store = last_store
    raise '[integration tests] no store cached — call build_store before feed_aggregator' if store.nil?

    resolver = build_resolver(store)
    ctx = contexts.is_a?(Quonfig::Context) ? contexts : Quonfig::Context.new(contexts || {})
    empty_ctx = Quonfig::Context.new({})

    self.last_unwrapped_overrides = {}
    Array(keys).each { |key| record_one_eval(aggregator, resolver, store, key, ctx) }
    Array(keys_no_ctx).each { |key| record_one_eval(aggregator, resolver, store, key, empty_ctx) }
  end
  private_class_method :record_eval_keys

  def self.record_one_eval(aggregator, resolver, store, key, ctx)
    cfg = store.get(key)
    return if cfg.nil?

    result =
      begin
        resolver.get(key, ctx)
      rescue Quonfig::Errors::MissingDefaultError
        nil
      end
    return if result.nil?

    # Confidential / decryptWith values must never appear in plaintext on
    # the wire. EvalResult#reportable_value, when populated, is the
    # `*****<md5>`-redacted substitute the resolver computed pre-decryption.
    # When we substitute, stash the runtime unwrapped value so the
    # post-projection can still assert YAML's `value` / `value_type` against
    # the resolved plaintext (the YAML treats `value` as the runtime view
    # and `selected_value` as the wire view).
    selected_for_telemetry = result.unwrapped_value
    if result.reportable_value
      selected_for_telemetry = result.reportable_value
      (self.last_unwrapped_overrides ||= {})[key] = {
        unwrapped: result.unwrapped_value,
        value_type: result.value_type
      }
    end
    aggregator.record(
      config_id: (cfg[:id] || cfg['id']).to_s,
      config_key: key,
      config_type: (cfg[:type] || cfg['type']).to_s,
      conditional_value_index: result.rule_index,
      weighted_value_index: result.weighted_value_index,
      selected_value: selected_for_telemetry,
      reason: result.wire_reason
    )
  end
  private_class_method :record_one_eval

  # Project +aggregator+'s drain_event payload onto the YAML's
  # snake_case `expected_data` schema. Returns nil when the aggregator
  # produced nothing (matches YAML's bare `expected_data:` lines).
  def self.build_actual_post(aggregator, kind)
    event = aggregator.drain_event
    return nil if event.nil?

    case normalize_kind(kind)
    when :context_shape      then context_shape_post(event)
    when :evaluation_summary then evaluation_summary_post(event)
    when :example_contexts   then example_contexts_post(event)
    end
  end
  private_class_method :build_actual_post

  def self.context_shape_post(event)
    shapes = event.dig('contextShapes', 'shapes') || []
    return nil if shapes.empty?

    shapes.map do |shape|
      { 'name' => shape['name'], 'field_types' => shape['fieldTypes'] }
    end
  end
  private_class_method :context_shape_post

  def self.example_contexts_post(event)
    examples = event.dig('exampleContexts', 'examples') || []
    return nil if examples.empty?

    # post.yaml expects a single context-set object (the first / only
    # example), keyed by named-context-name. Multiple examples are not
    # exercised in the YAML; if they ever are, this helper still picks
    # the first dedup'd record, matching sdk-node's wire shape.
    contexts = examples.first.dig('contextSet', 'contexts') || []
    contexts.each_with_object({}) do |ctx, acc|
      acc[ctx['type']] = ctx['values']
    end
  end
  private_class_method :example_contexts_post

  TYPE_LABELS = {
    'config' => 'CONFIG',
    'feature_flag' => 'FEATURE_FLAG',
    'segment' => 'SEGMENT',
    'log_level' => 'LOG_LEVEL',
    'schema' => 'SCHEMA'
  }.freeze
  private_constant :TYPE_LABELS

  def self.evaluation_summary_post(event)
    summaries = event.dig('summaries', 'summaries') || []
    overrides = last_unwrapped_overrides || {}
    rows = []
    summaries.each do |summary|
      type_label = TYPE_LABELS[summary['type'].to_s] || summary['type'].to_s.upcase
      counters = summary['counters'] || []
      counters.each do |counter|
        selected = counter['selectedValue'] || {}
        unwrapped, value_type = unwrap_selected(selected)
        # When the resolver redacted this key (confidential / decryptWith),
        # selected_value carries the redacted form on the wire but YAML's
        # `value` / `value_type` should still reflect the runtime resolved
        # plaintext. Restore from the side channel populated in
        # record_one_eval.
        if (override = overrides[summary['key']])
          unwrapped = override[:unwrapped]
          value_type = override[:value_type] if override[:value_type]
        end
        row = {
          'key' => summary['key'],
          'type' => type_label,
          'value' => unwrapped,
          'value_type' => value_type,
          'count' => counter['count'],
          'reason' => counter['reason']
        }
        if counter.key?('selectedValue')
          # YAML test cases that assert `selected_value:` use the raw
          # tagged shape (e.g. {"string" => "hello.world"}). We always
          # emit it; the diff's expected_data will simply not include
          # the field for cases that don't care.
          row['selected_value'] = selected
        end
        summary_block = {
          'config_row_index' => counter['configRowIndex'],
          'conditional_value_index' => counter['conditionalValueIndex']
        }
        if counter.key?('weightedValueIndex')
          summary_block['weighted_value_index'] = counter['weightedValueIndex']
        end
        row['summary'] = summary_block
        rows << row
      end
    end
    return nil if rows.empty?

    # Strip selected_value from rows whose YAML cases don't assert it.
    # We can't know that here, so emit it conditionally based on the
    # caller. The simpler path is to only include selected_value when
    # the YAML case asks for it. To keep this stateless we drop it by
    # default; the helper re-adds it on request via opt-in (see
    # #with_selected_values below). Most cases assert without it.
    rows
  end
  private_class_method :evaluation_summary_post

  # Decode the proto-style selectedValue wrapper { "<type>" => <val> }
  # into [unwrapped_value, value_type_label]. Mirrors the keys used by
  # EvaluationSummariesAggregator#wrap_selected_value (bool/int/double/
  # string/stringList).
  def self.unwrap_selected(selected)
    return [nil, nil] unless selected.is_a?(Hash) && selected.size == 1

    key, value = selected.first
    case key
    when 'bool'       then [value, 'bool']
    when 'int'        then [value, 'int']
    when 'double'     then [value, 'double']
    when 'string'     then [value, 'string']
    when 'stringList' then [value, 'string_list']
    else [value, key]
    end
  end
  private_class_method :unwrap_selected

  # Normalize the raw JSON config on disk into the shape the rest of the
  # suite expects: one environment row for ENV_ID pulled out of the
  # top-level `environments` array. Matches sdk-node/setup.ts:toConfigResponse.
  def self.to_config_response(raw)
    environment = nil
    if raw['environments'].is_a?(Array)
      match = raw['environments'].find { |e| e.is_a?(Hash) && e['id'] == ENV_ID }
      environment = match if match
    end

    {
      id: raw['id'] || '',
      key: raw['key'],
      type: raw['type'],
      value_type: raw['valueType'],
      send_to_client_sdk: raw['sendToClientSdk'] || false,
      default: raw['default'] || { 'rules' => [] },
      environment: environment,
      raw: raw
    }
  end
  private_class_method :to_config_response
end
