# frozen_string_literal: true

module CommonHelpers
  require 'timecop'

  def setup
    $oldstderr, $stderr = $stderr, StringIO.new
    $logs = StringIO.new

    if defined?(SemanticLogger)
      SemanticLogger.add_appender(io: $logs)
      SemanticLogger.sync!
    end
  end

  def teardown
    if $logs && !$logs.string.empty?
      log_lines = $logs.string.split("\n").reject do |line|
        line.match(/Quonfig::ConfigClient -- No success loading checkpoints/)
      end

      if log_lines.size > 0
        $logs = nil
        raise "Unexpected logs. Handle logs with assert_logged\n\n#{log_lines}"
      end
    end

    # note this skips the output check in environments like rubymine that hijack the output
    if $stderr != $oldstderr && $stderr.respond_to?(:string) && !$stderr.string.empty?
      if !RUBY_VERSION.start_with?('2.')
        # Filter out ld-eventsource frozen string literal warnings in Ruby 3.4+
        stderr_lines = $stderr.string.split("\n").reject do |line|
          line.include?('ld-eventsource') && line.include?('literal string will be frozen in the future')
        end

        if !stderr_lines.empty?
          raise "Unexpected stderr. Handle stderr with assert_stderr\n\n#{stderr_lines.join("\n")}"
        end
      end
    end

    $stderr = $oldstderr if $oldstderr

    Timecop.return
  end

  def with_env(key, value, &block)
    old_value = ENV.fetch(key, nil)

    ENV[key] = value
    block.call
  ensure
    ENV[key] = old_value
  end

  FakeResponse = Struct.new(:status, :body)

  def wait_for(condition, max_wait: 10, sleep_time: 0.01)
    wait_time = 0
    while !condition.call
      wait_time += sleep_time
      sleep sleep_time

      raise "Waited #{max_wait} seconds for the condition to be true, but it never was" if wait_time > max_wait
    end
  end

  def context(properties)
    Quonfig::Context.new(properties)
  end

  def assert_logged(expected)
    # we do a uniq here because logging can happen in a separate thread so the
    # number of times a log might happen could be slightly variable.
    actuals = $logs.string.split("\n").uniq
    expected.each do |expectation|
      matched = false

      actuals.each do |actual|
        matched = true if actual.match(expectation)
      end

      assert(matched, "expectation: #{expectation}, got: #{actuals}")
    end
    # mark nil to indicate we handled it
    $logs = nil
  end

  def assert_stderr(expected)
    skip "Cannot verify stderr in current environment" unless $stderr.respond_to?(:string)
    $stderr.string.split("\n").uniq.each do |line|
      matched = false

      expected.reject! do |expectation|
        matched = true if line.include?(expectation)
      end

      assert(matched, "expectation: #{expected}, got: #{line}")
    end

    assert expected.empty?, "Expected stderr to include: #{expected}, but it did not"

    # restore since we've handled it
    $stderr = $oldstderr
  end
end
