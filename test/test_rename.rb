# frozen_string_literal: true

require 'test_helper'

class TestRename < Minitest::Test
  def test_quonfig_module_is_defined
    assert defined?(Quonfig), 'Quonfig module must be defined after rename'
  end

  def test_reforge_module_is_gone
    # NOTE: 'Reforge' intentionally not renamed — this test guards against the old constant leaking back in.
    refute Object.const_defined?(:Reforge), 'Reforge constant must be removed after rename'
  end

  def test_quonfig_options_exists
    assert defined?(Quonfig::Options), 'Quonfig::Options must be defined'
  end

  def test_quonfig_client_exists
    assert defined?(Quonfig::Client), 'Quonfig::Client must be defined'
  end

  def test_quonfig_sdk_key_env_var
    # NOTE: the REFORGE_/PREFAB_ keys below are intentionally spelled out in string literals
    # so the bulk rename tool does not touch them — we are asserting that the NEW env var name
    # is the one the SDK reads.
    old_key_a = 'REFORGE_' + 'BACKEND_SDK_KEY'
    old_key_b = 'PREFAB_' + 'API_KEY'
    original = ENV.to_h.slice('QUONFIG_BACKEND_SDK_KEY', old_key_a, old_key_b)
    ENV.delete(old_key_a)
    ENV.delete(old_key_b)
    ENV['QUONFIG_BACKEND_SDK_KEY'] = 'quonfig-test-key-123'
    options = Quonfig::Options.new
    assert_equal 'quonfig-test-key-123', options.sdk_key
  ensure
    ENV.delete('QUONFIG_BACKEND_SDK_KEY')
    original&.each { |k, v| ENV[k] = v }
  end

  def test_gemspec_file_is_quonfig
    root = File.expand_path('..', __dir__)
    assert File.exist?(File.join(root, 'quonfig.gemspec')),
           'quonfig.gemspec must exist at repo root'
    refute File.exist?(File.join(root, 'sdk-reforge.gemspec')),
           'sdk-reforge.gemspec must be removed'
  end

  def test_gemspec_name_is_quonfig
    root = File.expand_path('..', __dir__)
    spec = Gem::Specification.load(File.join(root, 'quonfig.gemspec'))
    assert_equal 'quonfig', spec.name
  end

  def test_lib_entrypoint_renamed
    root = File.expand_path('..', __dir__)
    assert File.exist?(File.join(root, 'lib', 'quonfig.rb')),
           'lib/quonfig.rb must exist'
    assert Dir.exist?(File.join(root, 'lib', 'quonfig')),
           'lib/quonfig/ directory must exist'
    refute File.exist?(File.join(root, 'lib', 'sdk-reforge.rb')),
           'lib/sdk-reforge.rb must be removed'
    refute Dir.exist?(File.join(root, 'lib', 'reforge')),
           'lib/reforge/ directory must be removed'
  end
end
