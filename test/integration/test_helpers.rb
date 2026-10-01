# frozen_string_literal: true

require 'json'
require 'socket'
require 'webrick'
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

# Support code for the generated integration tests in
# sdk-ruby/test/integration/test_*.rb (generator:
# integration-test-data/generators/src/targets/ruby.ts).
#
# qfg-2agi.33: every generated case drives the PUBLIC Quonfig::Client exactly
# as a customer would — a datadir client, the typed getter / enabled? /
# get_or_raise the YAML names, global_context / with_context / in_context for
# the context tiers, and the real telemetry reporter flushed to a local HTTP
# sink. Nothing here resolves a config, maps an exception, or redacts a value
# on the SDK's behalf; if the SDK gets it wrong, the test goes red.
module IntegrationTestHelpers
  DATA_DIR = File.expand_path(
    '../../../integration-test-data/data/integration-tests',
    __dir__
  )
  ENV_ID = 'Production'

  # Warnings the SDK is REQUIRED to log on paths the shared YAML exercises on
  # purpose. The harness teardown rejects any unhandled log line, so these are
  # dropped; anything else still fails the test.
  EXPECTED_WARNINGS = [
    # Weighted rollout whose hash property is missing (qfg-9dxb.8 / qfg-46e1).
    /which is missing from context; hashing an empty value instead/,
    # Malformed duration -> default/nil, warn once per key (qfg-2agi.10).
    /is not a valid ISO-8601 duration/,
    # A single explicit api_url disables failover (qfg-41nh.26).
    /explicit api_urls disables automatic failover/
  ].freeze

  def self.data_dir
    unless Dir.exist?(DATA_DIR)
      raise "[integration tests] fixtures not found at #{DATA_DIR} — " \
            'clone quonfig/integration-test-data as a sibling of sdk-ruby.'
    end

    DATA_DIR
  end

  # A datadir-mode Quonfig::Client over the shared integration-test corpus,
  # evaluating the 'Production' environment. +opts+ are public client options
  # taken from the case (global_context:, on_no_default:, ...).
  #
  # sdk_key: nil and enable_quonfig_user_context: false keep the developer's
  # ambient QUONFIG_BACKEND_SDK_KEY / ~/.quonfig/tokens.json out of the result.
  def self.build_client(**opts)
    Quonfig::Client.new(
      datadir: data_dir,
      environment: ENV_ID,
      sdk_key: nil,
      enable_quonfig_user_context: false,
      **opts
    )
  end

  # A client whose initial network fetch cannot succeed (unreachable api_url +
  # tiny init timeout) for the initialization_timeout / on_init_failure cases.
  def self.build_network_client(api_url:, timeout_sec:, on_init_failure:)
    Quonfig::Client.new(
      sdk_key: 'test-unused',
      api_urls: [api_url.to_s.empty? ? 'https://127.0.0.1:1' : api_url],
      initialization_timeout_sec: timeout_sec,
      on_init_failure: on_init_failure,
      enable_sse: false,
      enable_polling: false,
      enable_quonfig_user_context: false
    )
  end

  # Drop the EXPECTED_WARNINGS lines from the captured log so the teardown
  # only trips on unexpected output.
  def self.acknowledge_expected_warnings
    return unless $logs.respond_to?(:string)

    kept = $logs.string.lines.reject { |line| EXPECTED_WARNINGS.any? { |re| line.match?(re) } }
    $logs.truncate(0)
    $logs.rewind
    $logs.write(kept.join)
  end

  # Temporarily set env vars for the duration of the block and restore the
  # originals (including absence) on exit — even if the block raises.
  def self.with_env(vars_hash)
    originals = {}
    vars_hash.each do |k, v|
      originals[k] = ENV.fetch(k, nil)
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
  # Telemetry (post.yaml / telemetry.yaml)
  # ----------------------------------------------------------------------
  #
  # The real path: a datadir client WITH an SDK key (the telemetry gate) whose
  # telemetry_url points at TelemetrySink, a local HTTP server. The generated
  # test evaluates through the public client, then flushes the client's own
  # TelemetryReporter, and the POST body the sink received is projected onto
  # the YAML's snake_case expected_data.

  # Local HTTP server that records every telemetry POST body.
  class TelemetrySink
    attr_reader :port

    def self.start
      new.tap(&:start)
    end

    def initialize
      @bodies = []
      @mutex = Mutex.new
      @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(StringIO.new), AccessLog: [])
      @server.mount_proc('/') do |req, res|
        @mutex.synchronize { @bodies << req.body.to_s }
        res.status = 200
        res['Content-Type'] = 'application/json'
        res.body = '{}'
      end
      @port = @server.config[:Port]
    end

    def start
      @thread = Thread.new { @server.start }
      50.times do
        break if open?

        sleep 0.02
      end
    end

    def url
      "http://127.0.0.1:#{@port}"
    end

    def bodies
      @mutex.synchronize { @bodies.dup }
    end

    def stop
      @server.shutdown
      @thread&.join(1)
    end

    private

    def open?
      TCPSocket.new('127.0.0.1', @port).tap(&:close)
      true
    rescue StandardError
      false
    end
  end

  # A datadir client with telemetry ON, reporting to +sink+. +opts+ are the
  # case's client_overrides (context_upload_mode:, collect_evaluation_summaries:).
  def self.build_telemetry_client(sink, **opts)
    Quonfig::Client.new(
      datadir: data_dir,
      environment: ENV_ID,
      sdk_key: 'itd-telemetry-sdk-key',
      telemetry_url: sink.url,
      enable_quonfig_user_context: false,
      **opts
    )
  end

  # Flush the client's REAL telemetry reporter into +sink+ and assert the POST
  # it produced, projected for +kind+, matches +expected_data+.
  #
  # Eval-summary rows: the wire carries only selectedValue (redacted for
  # confidential / decryptWith configs). The YAML's `value` is the runtime
  # view, so it is checked against what the public getter actually returned
  # for that key (+returned+), and the rest of the row against the wire.
  def self.assert_telemetry_post(test, client, sink, kind, expected_data, endpoint:, returned: {})
    client.telemetry_reporter&.flush
    events = sink.bodies.flat_map { |body| JSON.parse(body).fetch('events', []) }
    actual = project(events, kind)

    if expected_data.nil?
      test.assert_nil actual, "[#{endpoint}] expected no #{kind} telemetry but the client sent #{actual.inspect}"
      return
    end

    if kind == :evaluation_summary
      expected_data.each do |row|
        test.assert_includes returned.fetch(row['key'], []), row['value'],
                             "[#{endpoint}] public getter for #{row['key']} did not return #{row['value'].inspect}"
      end
      expected_data = expected_data.map { |row| row.except('value') }
      actual = scrub_unasserted_selected_values(actual, expected_data)
    end

    test.assert_equal sort_rows(expected_data, kind), sort_rows(actual, kind),
                      "[#{endpoint}] telemetry POST mismatch"
  end

  def self.project(events, kind)
    case kind
    when :evaluation_summary then evaluation_summary_rows(events)
    when :context_shape      then context_shape_rows(events)
    when :example_contexts   then example_context_set(events)
    else raise ArgumentError, "Unknown telemetry kind: #{kind.inspect}"
    end
  end
  private_class_method :project

  def self.context_shape_rows(events)
    shapes = events.flat_map { |e| e.dig('contextShapes', 'shapes') || [] }
    return nil if shapes.empty?

    shapes.map { |shape| { 'name' => shape['name'], 'field_types' => shape['fieldTypes'] } }
  end
  private_class_method :context_shape_rows

  # post.yaml expects a single context-set object (the first example), keyed
  # by named-context name.
  def self.example_context_set(events)
    examples = events.flat_map { |e| e.dig('exampleContexts', 'examples') || [] }
    return nil if examples.empty?

    (examples.first.dig('contextSet', 'contexts') || []).to_h { |ctx| [ctx['type'], ctx['values']] }
  end
  private_class_method :example_context_set

  SELECTED_VALUE_TYPES = {
    'bool' => 'bool', 'int' => 'int', 'double' => 'double',
    'string' => 'string', 'stringList' => 'string_list'
  }.freeze

  def self.evaluation_summary_rows(events)
    summaries = events.flat_map { |e| e.dig('summaries', 'summaries') || [] }
    rows = summaries.flat_map do |summary|
      (summary['counters'] || []).map do |counter|
        selected = counter['selectedValue'] || {}
        summary_block = {
          'config_row_index' => counter['configRowIndex'],
          'conditional_value_index' => counter['conditionalValueIndex']
        }
        summary_block['weighted_value_index'] = counter['weightedValueIndex'] if counter.key?('weightedValueIndex')
        {
          'key' => summary['key'],
          'type' => summary['type'].to_s.upcase,
          'value_type' => SELECTED_VALUE_TYPES.fetch(selected.keys.first.to_s, selected.keys.first),
          'count' => counter['count'],
          'reason' => counter['reason'],
          'selected_value' => selected,
          'summary' => summary_block
        }
      end
    end
    rows.empty? ? nil : rows
  end
  private_class_method :evaluation_summary_rows

  # selected_value is opt-in per expected row; drop it from actual rows whose
  # expected counterpart (same key + conditional_value_index) omits it.
  def self.scrub_unasserted_selected_values(actual, expected)
    return actual unless actual.is_a?(Array)

    asserted = expected.select { |row| row.key?('selected_value') }
                       .map { |row| [row['key'], row.dig('summary', 'conditional_value_index')] }
    actual.map do |row|
      id = [row['key'], row.dig('summary', 'conditional_value_index')]
      asserted.include?(id) ? row : row.except('selected_value')
    end
  end
  private_class_method :scrub_unasserted_selected_values

  # Telemetry rows are an unordered set; sort both sides the same way.
  def self.sort_rows(rows, kind)
    return rows unless rows.is_a?(Array)

    case kind
    when :evaluation_summary
      rows.sort_by { |r| [r['key'].to_s, r.dig('summary', 'conditional_value_index') || 0] }
    when :context_shape
      rows.sort_by { |r| r['name'].to_s }
    else
      rows
    end
  end
  private_class_method :sort_rows
end
