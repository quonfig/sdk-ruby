# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'logger'

# qfg-mol-1qw.3 — Pluggable logger via Quonfig::Client.new(logger:).
#
# Host apps (Rails, etc.) want SDK warnings to flow through their own logger
# so they show up in app log streams instead of bare stderr. This test
# exercises the full path: an injected logger is passed via Options, picked
# up by InternalLogger, and receives a warn call routed through the LOG
# constant in DevContext when the tokens file fails to parse.
class TestLoggerInjection < Minitest::Test
  # Recording fake — captures messages per level. Intentionally implements
  # only debug/info/warn/error (no trace, no fatal) to verify InternalLogger
  # tolerates partial loggers.
  class FakeLogger
    attr_reader :messages

    def initialize
      @messages = Hash.new { |h, k| h[k] = [] }
    end

    def debug(msg = nil) = @messages[:debug] << (msg || (block_given? ? yield : nil))
    def info(msg = nil) = @messages[:info] << (msg || (block_given? ? yield : nil))
    def warn(msg = nil) = @messages[:warn] << (msg || (block_given? ? yield : nil))
    def error(msg = nil) = @messages[:error] << (msg || (block_given? ? yield : nil))
  end

  # Even more partial — has only warn/error. Used to verify InternalLogger
  # tolerates a logger missing :debug.
  class PartialLogger
    attr_reader :messages

    def initialize
      @messages = Hash.new { |h, k| h[k] = [] }
    end

    def warn(msg = nil) = @messages[:warn] << msg
    def error(msg = nil) = @messages[:error] << msg
  end

  def setup
    super
    @tmphome = Dir.mktmpdir('quonfig-logger-inj-')
    FileUtils.mkdir_p(File.join(@tmphome, '.quonfig'))
    @old_home = Dir.home
    ENV['HOME'] = @tmphome
    ENV.delete('QUONFIG_DEV_CONTEXT')
  end

  def teardown
    ENV['HOME'] = @old_home
    ENV.delete('QUONFIG_DEV_CONTEXT')
    FileUtils.remove_entry(@tmphome) if @tmphome && Dir.exist?(@tmphome)
    Quonfig::InternalLogger.user_logger = nil if Quonfig::InternalLogger.respond_to?(:user_logger=)
    super
  end

  def write_unparseable_tokens
    File.write(File.join(@tmphome, '.quonfig', 'tokens.json'), '{not valid json')
  end

  def test_dev_context_warning_routes_to_injected_logger
    write_unparseable_tokens
    fake = FakeLogger.new

    Quonfig::Client.new(
      Quonfig::Options.new(
        logger: fake,
        enable_quonfig_user_context: true
      ),
      store: Quonfig::ConfigStore.new
    )

    warn_lines = fake.messages[:warn].compact.join("\n")
    assert_match(/could not parse/, warn_lines,
                 "expected fake logger to receive dev-context parse warning, got: #{fake.messages.inspect}")
  end

  def test_options_exposes_logger_attr
    fake = FakeLogger.new
    options = Quonfig::Options.new(logger: fake)
    assert_same fake, options.logger
  end

  def test_omitting_logger_uses_stdlib_default
    options = Quonfig::Options.new
    assert_nil options.logger
  end

  def test_logger_missing_debug_does_not_crash
    write_unparseable_tokens
    partial = PartialLogger.new

    Quonfig::Client.new(
      Quonfig::Options.new(
        logger: partial,
        enable_quonfig_user_context: true
      ),
      store: Quonfig::ConfigStore.new
    )

    warn_lines = partial.messages[:warn].compact.join("\n")
    assert_match(/could not parse/, warn_lines)
  end

  def test_internal_logger_user_logger_class_setter_routes_writes
    fake = FakeLogger.new
    Quonfig::InternalLogger.user_logger = fake

    log = Quonfig::InternalLogger.new(self.class)
    log.warn('hello from sdk')

    warn_lines = fake.messages[:warn].compact.join("\n")
    assert_match(/hello from sdk/, warn_lines)
  ensure
    Quonfig::InternalLogger.user_logger = nil
  end
end
