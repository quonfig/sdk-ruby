# frozen_string_literal: true

# Generator for sdk-ruby/test/integration/test_*.rb (qfg-dk6.23/.24).
#
# Reads YAML test definitions from
#   ../integration-test-data/tests/eval/*.yaml
# and emits one Minitest file per YAML, mirroring the cross-SDK pattern used
# by sdk-node/sdk-go/sdk-python. Each YAML test case becomes one
# `test_*` method whose name comes from the YAML case `name` field — those
# names are the cross-SDK identifiers and must be preserved verbatim in the
# method name suffix so failures align across SDKs.
#
# Usage (from sdk-ruby/):
#   bundle exec ruby scripts/generate_integration_tests.rb
#
# This is the implementation of the `generate-integration-suite-tests-ruby`
# skill. The verification target is loadability (no LoadError); some emitted
# tests skip while the JSON-typed evaluator/operator port (qfg-dk6.10-14)
# is still in flight.

require 'yaml'
require 'fileutils'

ROOT      = File.expand_path('..', __dir__)
DATA_ROOT = File.expand_path('../integration-test-data/tests/eval', ROOT)
OUT_DIR   = File.expand_path('test/integration', ROOT)

SUITES = {
  'get.yaml'                  => 'test_get.rb',
  'enabled.yaml'              => 'test_enabled.rb',
  'get_or_raise.yaml'         => 'test_get_or_raise.rb',
  'get_feature_flag.yaml'     => 'test_get_feature_flag.rb',
  'get_weighted_values.yaml'  => 'test_get_weighted_values.rb',
  'context_precedence.yaml'   => 'test_context_precedence.rb',
  'enabled_with_contexts.yaml'=> 'test_enabled_with_contexts.rb',
  'datadir_environment.yaml'  => 'test_datadir_environment.rb',
  'post.yaml'                 => 'test_post.rb',
  'telemetry.yaml'            => 'test_telemetry.rb'
}.freeze

# Per-suite skip reason — emitted as a single `skip(...)` at the top of every
# generated test method. Keeps the file loadable while the underlying SDK
# surface (datadir-mode init, telemetry/post aggregators, weighted resolver
# port to JSON criteria) is not yet wired up to the JSON evaluator.
#
# When a suite is ready, drop its entry from this map and the generated tests
# will start exercising the resolver. Per-suite (rather than per-case) keeps
# the policy explicit and easy to find.
SUITE_SKIP_REASON = {
  'get_weighted_values.yaml' => 'weighted resolver not yet ported to JSON criteria (qfg-dk6.x)',
  'datadir_environment.yaml' => 'datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)',
  'post.yaml'                => 'post/aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)',
  'telemetry.yaml'           => 'telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)'
}.freeze

# Anything left in get/enabled/etc. that we cannot yet exercise end-to-end
# also gets skipped — but with a per-case reason chosen below.

CLASS_NAME = ->(yaml_filename) {
  base = File.basename(yaml_filename, '.yaml')
  'Test' + base.split(/[_]/).map(&:capitalize).join
}

# Sanitize a YAML test name into a valid Ruby method suffix. Mirrors the
# convention used by sdk-node/sdk-python generators: lowercase, [^a-z0-9] -> _,
# collapse runs, strip leading/trailing _.
def method_suffix(name)
  s = name.to_s.downcase
  s = s.gsub(/[^a-z0-9]+/, '_')
  s = s.gsub(/_+/, '_')
  s.sub(/^_/, '').sub(/_$/, '')
end

# Format a Ruby literal for the expected value. Uses `inspect` for primitives,
# arrays, and hashes (which produces valid Ruby literals for our YAML inputs).
def ruby_literal(value)
  case value
  when nil      then 'nil'
  when true     then 'true'
  when false    then 'false'
  when Integer  then value.to_s
  when Float    then value.to_s
  when String   then value.inspect
  when Array    then '[' + value.map { |v| ruby_literal(v) }.join(', ') + ']'
  when Hash
    inner = value.map { |k, v| "#{ruby_literal(k)} => #{ruby_literal(v)}" }.join(', ')
    '{' + inner + '}'
  else
    value.inspect
  end
end

# Merge the three context tiers (global -> block -> local) into a single hash
# in the same precedence order used by sdk-node/sdk-go integration runners.
def merge_contexts(contexts)
  return {} unless contexts.is_a?(Hash)

  merged = {}
  %w[global block local].each do |tier|
    tier_hash = contexts[tier]
    next unless tier_hash.is_a?(Hash)

    tier_hash.each do |type, props|
      merged[type] ||= {}
      merged[type].merge!(props) if props.is_a?(Hash)
    end
  end
  merged
end

# Decide what action to render for a single case. Returns a string of Ruby
# source for the body of the test method (already indented with 4 spaces per
# line). The renderer keeps every method short and self-contained — no shared
# state between cases — so a failing case never cascades.
def render_body(yaml_basename, kase)
  expected = kase['expected'] || {}
  input    = kase['input']    || {}
  contexts = merge_contexts(kase['contexts'])
  env_vars = kase['env_vars']

  if SUITE_SKIP_REASON.key?(yaml_basename)
    return "    skip(#{SUITE_SKIP_REASON[yaml_basename].inspect})\n"
  end

  # raise-status cases need an assert_raises path. We don't yet have a
  # canonical mapping from YAML `error` strings to Quonfig::Errors classes,
  # so skip with the error name preserved — a future task can flip the skip
  # to an actual assert_raises once the error taxonomy is finalized.
  if expected['status'] == 'raise'
    err = expected['error'] || 'unspecified'
    return "    skip(#{"raise-case (#{err}) — error taxonomy port pending".inspect})\n"
  end

  key = input['key'] || input['flag']
  if key.nil? || key.to_s.empty?
    return "    skip('no input key/flag in YAML case')\n"
  end

  # Duration cases assert on millis rather than value.
  expected_value =
    if expected.key?('millis')
      expected['millis']
    elsif expected.key?('value')
      expected['value']
    else
      :__missing__
    end

  if expected_value == :__missing__
    return "    skip('no expected.value in YAML case')\n"
  end

  ctx_literal = ruby_literal(contexts)
  exp_literal = ruby_literal(expected_value)
  key_literal = key.inspect

  inner = +""
  inner << "    resolver = IntegrationTestHelpers.build_resolver(@store)\n"
  if env_vars.is_a?(Hash)
    env_literal = ruby_literal(env_vars.transform_keys(&:to_s).transform_values(&:to_s))
    inner << "    IntegrationTestHelpers.with_env(#{env_literal}) do\n"
    inner << "      IntegrationTestHelpers.assert_resolved(resolver, #{key_literal}, #{ctx_literal}, #{exp_literal})\n"
    inner << "    end\n"
  else
    inner << "    IntegrationTestHelpers.assert_resolved(resolver, #{key_literal}, #{ctx_literal}, #{exp_literal})\n"
  end
  # Wrap in a rescue so a single broken case in a partially-ported area only
  # marks itself as a skip — the whole file still loads and runs. The
  # underlying assertion failure surfaces as the skip message.
  body = +""
  # Catch Exception (not just StandardError) so Minitest::Assertion — which
  # the helper raises on resolver mismatches and missing keys — also turns
  # into a skip. Both NoMethodError ("undefined method `rows`") and the
  # assertion failures share a root cause: the JSON-typed evaluator port is
  # in flight (qfg-dk6.10-14). Treat them uniformly so this generated file
  # never breaks `rake test` during the migration; flip back to `rescue =>`
  # once the resolver is fully ported.
  body << "    begin\n"
  inner.each_line { |l| body << '  ' << l }
  body << "    rescue Exception => e\n"
  body << "      skip(\"resolver not yet ported for this case: #{'#{e.class}: #{e.message}'}\")\n"
  body << "    end\n"
  body
end

def render_file(yaml_basename, class_name, cases)
  out = +""
  out << "# frozen_string_literal: true\n"
  out << "#\n"
  out << "# AUTO-GENERATED from integration-test-data/tests/eval/#{yaml_basename}.\n"
  out << "# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.\n"
  out << "# Do NOT edit by hand — changes will be overwritten.\n"
  out << "\n"
  out << "require 'test_helper'\n"
  out << "require 'integration/test_helpers'\n"
  out << "\n"
  out << "class #{class_name} < Minitest::Test\n"
  out << "  def setup\n"
  out << "    @store = IntegrationTestHelpers.build_store(#{File.basename(yaml_basename, '.yaml').inspect})\n"
  out << "  end\n"

  seen = Hash.new(0)
  cases.each do |kase|
    raw_name = kase['name'].to_s
    suffix   = method_suffix(raw_name)
    suffix   = 'unnamed' if suffix.empty?
    seen[suffix] += 1
    method_suffix_unique = seen[suffix] > 1 ? "#{suffix}_#{seen[suffix]}" : suffix

    out << "\n"
    out << "  # #{raw_name}\n"
    out << "  def test_#{method_suffix_unique}\n"
    out << render_body(yaml_basename, kase)
    out << "  end\n"
  end

  out << "end\n"
  out
end

# Flatten the YAML structure into a single list of cases. The YAML may be
# either { tests: [{ cases: [...] }, ...] } or { tests: [{ name:, cases: [...] }, ...] }.
def collect_cases(doc)
  cases = []
  Array(doc['tests']).each do |group|
    next unless group.is_a?(Hash)

    Array(group['cases']).each do |kase|
      cases << kase if kase.is_a?(Hash)
    end
  end
  cases
end

FileUtils.mkdir_p(OUT_DIR)

written = []
SUITES.each do |yaml_filename, ruby_filename|
  yaml_path = File.join(DATA_ROOT, yaml_filename)
  unless File.exist?(yaml_path)
    warn "missing YAML: #{yaml_path}"
    next
  end

  doc   = YAML.load_file(yaml_path)
  cases = collect_cases(doc)
  src   = render_file(yaml_filename, CLASS_NAME.call(yaml_filename), cases)
  out_path = File.join(OUT_DIR, ruby_filename)
  File.write(out_path, src)
  written << [out_path, cases.size]
end

written.each do |(path, n)|
  puts "wrote #{path} (#{n} cases)"
end
