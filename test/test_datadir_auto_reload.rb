# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

# qfg-mol-2da — opt-in data_dir_auto_reload: when files inside the configured
# datadir change on disk, the SDK re-reads via Quonfig::Datadir.load_envelope,
# atomically swaps the in-memory store, and fires the existing on_update
# callback. Mirrors sdk-node's dataDirAutoReload (qfg-mol-0kr).
class TestDatadirAutoReload < Minitest::Test
  CONFIG_SUBDIRS = %w[configs feature-flags segments log-levels].freeze

  def setup
    super
    @tmpdir = Dir.mktmpdir('quonfig-autoreload-test')
    CONFIG_SUBDIRS.each { |sub| FileUtils.mkdir_p(File.join(@tmpdir, sub)) }
    File.write(
      File.join(@tmpdir, 'quonfig.json'),
      JSON.generate({ environments: %w[Production Staging] })
    )
    @clients = []
    @tmpdirs = [@tmpdir]
  end

  def teardown
    @clients.each do |c|
      c.stop
    rescue StandardError
      # already torn down
    end
    @tmpdirs.each do |path|
      next unless path

      if File.symlink?(path)
        File.unlink(path)
      else
        FileUtils.rm_rf(path)
      end
    end
    super
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def write_config(dir, key, string_value)
    body = {
      'id' => "id-#{key}",
      'key' => key,
      'type' => 'config',
      'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => 'string', 'value' => string_value } }
        ]
      },
      'environments' => []
    }
    File.write(File.join(dir, 'configs', "#{key}.json"), JSON.generate(body))
  end

  def build_client(opts = {})
    client = Quonfig::Client.new(
      Quonfig::Options.new(
        datadir: @tmpdir,
        environment: 'Production',
        on_no_default: :return_nil,
        context_upload_mode: :none,
        **opts
      )
    )
    @clients << client
    # macOS FSEvents has ~100ms baseline latency *after* the listener reports
    # ready. Sleep briefly so writes that happen right after Client.new are
    # reliably captured by the watcher. Real customers do not modify config
    # files within the first millisecond of initialization, so this is a
    # test-only concession.
    sleep 0.25 if opts[:data_dir_auto_reload]
    client
  end

  # ------------------------------------------------------------------
  # Tests
  # ------------------------------------------------------------------

  def test_reloads_envelope_and_fires_on_update_when_config_file_is_rewritten
    write_config(@tmpdir, 'welcome', 'hola')

    callback_count = 0
    client = build_client(data_dir_auto_reload: true, data_dir_auto_reload_debounce_ms: 50)
    client.on_update { callback_count += 1 }

    assert_equal 'hola', client.get('welcome')

    write_config(@tmpdir, 'welcome', 'buenos-dias')

    wait_for(-> { client.get('welcome') == 'buenos-dias' }, max_wait: 5)
    assert_operator callback_count, :>=, 1, 'on_update must fire after datadir auto-reload'
  end

  def test_disabled_by_default_no_reload_no_callback
    write_config(@tmpdir, 'welcome', 'hola')

    callback_count = 0
    client = build_client # no data_dir_auto_reload kwarg → default false
    client.on_update { callback_count += 1 }

    assert_equal 'hola', client.get('welcome')

    write_config(@tmpdir, 'welcome', 'ignored')
    sleep 0.4 # longer than any reasonable debounce

    assert_equal 0, callback_count, 'on_update must not fire when auto-reload is off'
    assert_equal 'hola', client.get('welcome'), 'store must keep the original value'
  end

  def test_burst_of_writes_coalesces_to_a_single_reload_callback
    write_config(@tmpdir, 'welcome', 'v0')

    extra_callbacks = 0
    client = build_client(data_dir_auto_reload: true, data_dir_auto_reload_debounce_ms: 150)
    client.on_update { extra_callbacks += 1 }

    # Five rapid rewrites of the same file inside the debounce window.
    5.times do |i|
      write_config(@tmpdir, 'welcome', "v#{i + 1}")
      sleep 0.01
    end

    wait_for(-> { client.get('welcome') == 'v5' }, max_wait: 5)
    sleep 0.3 # let any straggler timers flush

    assert_equal 1, extra_callbacks,
                 "burst of 5 writes within 150ms debounce must coalesce to one callback (got #{extra_callbacks})"
  end

  def test_parse_error_keeps_previous_envelope_and_does_not_fire_callback
    write_config(@tmpdir, 'welcome', 'hola')

    extra_callbacks = 0
    client = build_client(data_dir_auto_reload: true, data_dir_auto_reload_debounce_ms: 50)
    client.on_update { extra_callbacks += 1 }
    assert_equal 'hola', client.get('welcome')

    # Write malformed JSON — the loader will raise.
    File.write(File.join(@tmpdir, 'configs', 'welcome.json'), '{not valid json')
    sleep 0.4

    assert_equal 'hola', client.get('welcome'),
                 'malformed JSON must NOT swap the envelope (parse-then-swap invariant)'
    assert_equal 0, extra_callbacks,
                 'on_update must not fire on a failed reload'

    assert_logged([/datadir reload failed; keeping previous envelope/])
  end

  def test_stop_terminates_the_watcher_and_no_further_callbacks_fire
    write_config(@tmpdir, 'welcome', 'hola')

    callback_count = 0
    client = build_client(data_dir_auto_reload: true, data_dir_auto_reload_debounce_ms: 50)
    client.on_update { callback_count += 1 }

    write_config(@tmpdir, 'welcome', 'v1')
    wait_for(-> { client.get('welcome') == 'v1' }, max_wait: 5)
    before_stop = callback_count

    client.stop

    # Post-stop writes must not trigger callbacks.
    write_config(@tmpdir, 'welcome', 'v2')
    sleep 0.4

    assert_equal before_stop, callback_count,
                 'stop() must tear down the watcher — no callbacks after stop'
  end

  def test_symlink_datadir_is_resolved_and_watched
    real_dir = Dir.mktmpdir('quonfig-autoreload-real')
    @tmpdirs << real_dir
    CONFIG_SUBDIRS.each { |sub| FileUtils.mkdir_p(File.join(real_dir, sub)) }
    File.write(
      File.join(real_dir, 'quonfig.json'),
      JSON.generate({ environments: %w[Production] })
    )
    write_config(real_dir, 'welcome', 'hola')

    symlink_path = File.join(Dir.tmpdir, "quonfig-autoreload-symlink-#{rand(1 << 30)}")
    FileUtils.ln_s(real_dir, symlink_path)
    @tmpdirs << symlink_path # cleanup also removes the symlink

    client = Quonfig::Client.new(
      Quonfig::Options.new(
        datadir: symlink_path,
        environment: 'Production',
        on_no_default: :return_nil,
        context_upload_mode: :none,
        data_dir_auto_reload: true,
        data_dir_auto_reload_debounce_ms: 50
      )
    )
    @clients << client

    assert_equal 'hola', client.get('welcome')
    sleep 0.25 # FSEvents warmup, see build_client

    # Modify the real file (the symlink resolves to it).
    write_config(real_dir, 'welcome', 'buenos-dias')

    wait_for(-> { client.get('welcome') == 'buenos-dias' }, max_wait: 5)
  end

  def test_listen_registration_failure_logs_and_downgrades_gracefully
    write_config(@tmpdir, 'welcome', 'hola')

    fake_listener_class = Class.new do
      def self.to(*_args, **_kwargs, &_block)
        raise StandardError, 'simulated listen registration failure'
      end
    end

    silence_warnings_about_constant_change do
      original = Quonfig::DatadirWatcher.const_get(:LISTEN_FACTORY)
      Quonfig::DatadirWatcher.const_set(:LISTEN_FACTORY, fake_listener_class)
      begin
        # Should NOT raise — the client must keep serving the original envelope.
        client = Quonfig::Client.new(
          Quonfig::Options.new(
            datadir: @tmpdir,
            environment: 'Production',
            on_no_default: :return_nil,
            context_upload_mode: :none,
            data_dir_auto_reload: true,
            data_dir_auto_reload_debounce_ms: 50
          )
        )
        @clients << client
        assert_equal 'hola', client.get('welcome'),
                     'client must keep serving the initial envelope even when watcher registration fails'
        assert_nil client.instance_variable_get(:@datadir_watcher),
                   'failed registration must leave the watcher unset'
      ensure
        Quonfig::DatadirWatcher.const_set(:LISTEN_FACTORY, original)
      end
    end

    assert_logged([
                    /datadir watcher error.*simulated listen registration failure/,
                    /watcher registration failed; continuing without auto-reload/
                  ])
  end

  # Fork lifecycle: before_fork_in_parent must stop the watcher; after_fork_in_child
  # must restart it on the same Client instance.
  def test_fork_lifecycle_stops_and_restarts_the_watcher
    write_config(@tmpdir, 'welcome', 'hola')

    client = build_client(data_dir_auto_reload: true, data_dir_auto_reload_debounce_ms: 50)
    original_watcher = client.instance_variable_get(:@datadir_watcher)
    refute_nil original_watcher, 'watcher must be wired when data_dir_auto_reload is on'

    client.before_fork_in_parent
    assert_nil client.instance_variable_get(:@datadir_watcher),
               'before_fork_in_parent must drop the watcher reference'

    client.after_fork_in_child
    new_watcher = client.instance_variable_get(:@datadir_watcher)
    refute_nil new_watcher, 'after_fork_in_child must rebuild the watcher'
    refute_same original_watcher, new_watcher,
                'after_fork_in_child must allocate a fresh watcher instance'

    # The fresh watcher must actually drive reloads.
    sleep 0.25 # FSEvents warmup for the freshly-registered watch
    write_config(@tmpdir, 'welcome', 'post-fork')
    wait_for(-> { client.get('welcome') == 'post-fork' }, max_wait: 5)
  end

  private

  def silence_warnings_about_constant_change
    original_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = original_verbose
  end
end
