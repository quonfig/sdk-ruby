# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

# qfg-pj0.5 — Dev-context injection. When enable_quonfig_user_context: true
# (or env var QUONFIG_DEV_CONTEXT=true), the SDK reads ~/.quonfig/tokens.json
# (written by `qfg login`) and merges {'quonfig-user' => {'email' => ...}}
# into globalContext. Customer-supplied keys win on collision.
#
# Mirror of sdk-node qfg-pj0.3 / sdk-go qfg-pj0.4.
class TestDevContext < Minitest::Test
  def setup
    super
    @tmphome = Dir.mktmpdir('quonfig-dev-ctx-')
    FileUtils.mkdir_p(File.join(@tmphome, '.quonfig'))
    @old_home = Dir.home
    ENV['HOME'] = @tmphome
    ENV.delete('QUONFIG_DEV_CONTEXT')
  end

  def teardown
    ENV['HOME'] = @old_home
    ENV.delete('QUONFIG_DEV_CONTEXT')
    FileUtils.remove_entry(@tmphome) if @tmphome && Dir.exist?(@tmphome)
    super
  end

  def write_tokens(payload)
    File.write(File.join(@tmphome, '.quonfig', 'tokens.json'), JSON.generate(payload))
  end

  def global_context_of(client)
    client.instance_variable_get(:@global_context)
  end

  # 1. RED: injects quonfig-user.email when option enabled and file exists
  def test_injects_quonfig_user_email_when_option_enabled
    write_tokens(userEmail: 'bob@foo.com', accessToken: 'x', refreshToken: 'y', expiresAt: 0)

    client = Quonfig::Client.new(
      Quonfig::Options.new(enable_quonfig_user_context: true),
      store: Quonfig::ConfigStore.new
    )

    assert_equal({ 'quonfig-user' => { 'email' => 'bob@foo.com' } }, global_context_of(client))
  end

  # 2. The flip: enabled by DEFAULT (no opt-in, no env var) when the token
  # file is present; customer context preserved alongside the injection.
  def test_enabled_by_default
    write_tokens(userEmail: 'bob@foo.com')

    client = Quonfig::Client.new(
      Quonfig::Options.new(global_context: { user: { 'plan' => 'pro' } }),
      store: Quonfig::ConfigStore.new
    )

    assert_equal(
      { user: { 'plan' => 'pro' }, 'quonfig-user' => { 'email' => 'bob@foo.com' } },
      global_context_of(client)
    )
  end

  # 2b. explicit enable_quonfig_user_context: false disables despite token
  def test_option_false_disables
    write_tokens(userEmail: 'bob@foo.com')

    client = Quonfig::Client.new(
      Quonfig::Options.new(enable_quonfig_user_context: false),
      store: Quonfig::ConfigStore.new
    )

    assert_equal({}, global_context_of(client))
  end

  # 2c. QUONFIG_DEV_CONTEXT=false disables despite token
  def test_env_false_disables
    write_tokens(userEmail: 'bob@foo.com')
    ENV['QUONFIG_DEV_CONTEXT'] = 'false'

    client = Quonfig::Client.new(
      Quonfig::Options.new,
      store: Quonfig::ConfigStore.new
    )

    assert_equal({}, global_context_of(client))
  end

  # 2d. explicit option true overrides QUONFIG_DEV_CONTEXT=false
  def test_option_true_overrides_env_false
    write_tokens(userEmail: 'bob@foo.com')
    ENV['QUONFIG_DEV_CONTEXT'] = 'false'

    client = Quonfig::Client.new(
      Quonfig::Options.new(enable_quonfig_user_context: true),
      store: Quonfig::ConfigStore.new
    )

    assert_equal({ 'quonfig-user' => { 'email' => 'bob@foo.com' } }, global_context_of(client))
  end

  # 3. RED: no-op when option enabled but file missing
  def test_no_op_when_file_missing
    # No tokens.json written.
    client = Quonfig::Client.new(
      Quonfig::Options.new(
        enable_quonfig_user_context: true,
        global_context: { user: { 'plan' => 'pro' } }
      ),
      store: Quonfig::ConfigStore.new
    )

    assert_equal({ user: { 'plan' => 'pro' } }, global_context_of(client))
  end

  # 4. RED: no-op when file unparseable; warning emitted; init succeeds
  def test_no_op_when_file_unparseable
    File.write(File.join(@tmphome, '.quonfig', 'tokens.json'), '{not valid json')

    client = Quonfig::Client.new(
      Quonfig::Options.new(enable_quonfig_user_context: true),
      store: Quonfig::ConfigStore.new
    )

    assert_equal({}, global_context_of(client))
    # qfg-mol-1qw.3: dev-context now routes warnings through InternalLogger.
    assert_logged([/dev-context: could not parse/])
  end

  # 5. RED: customer-supplied quonfig-user keys win on collision
  def test_customer_global_context_wins
    write_tokens(userEmail: 'bob@foo.com')

    client = Quonfig::Client.new(
      Quonfig::Options.new(
        enable_quonfig_user_context: true,
        global_context: { 'quonfig-user' => { 'email' => 'override@x.com' } }
      ),
      store: Quonfig::ConfigStore.new
    )

    assert_equal({ 'quonfig-user' => { 'email' => 'override@x.com' } }, global_context_of(client))
  end

  # 6. RED: env var QUONFIG_DEV_CONTEXT=true enables when option absent
  def test_env_var_enables_when_option_absent
    write_tokens(userEmail: 'bob@foo.com')
    ENV['QUONFIG_DEV_CONTEXT'] = 'true'

    client = Quonfig::Client.new(
      Quonfig::Options.new,
      store: Quonfig::ConfigStore.new
    )

    assert_equal({ 'quonfig-user' => { 'email' => 'bob@foo.com' } }, global_context_of(client))
  end

  # 7. RED: integration — rule keyed on quonfig-user.email fires when injected
  def test_attribute_reaches_eval_context
    write_tokens(userEmail: 'bob@foo.com')

    flag_config = {
      'id' => 'cfg-flag',
      'key' => 'my-flag',
      'type' => 'feature_flag',
      'valueType' => 'bool',
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'bool', 'value' => false } }
        ]
      },
      'environment' => {
        'id' => 'Production',
        'rules' => [
          {
            'criteria' => [{
              'propertyName' => 'quonfig-user.email',
              'operator' => 'PROP_IS_ONE_OF',
              'valueToMatch' => { 'type' => 'string_list', 'value' => ['bob@foo.com'] }
            }],
            'value' => { 'type' => 'bool', 'value' => true }
          },
          { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'bool', 'value' => false } }
        ]
      }
    }

    store = Quonfig::ConfigStore.new
    store.set('my-flag', flag_config)

    client = Quonfig::Client.new(
      Quonfig::Options.new(
        enable_quonfig_user_context: true,
        environment: 'Production'
      ),
      store: store
    )

    assert_equal true, client.get_bool('my-flag')
  end
end
