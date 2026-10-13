# frozen_string_literal: true

require 'test_helper'

# qfg-goi1.10.2 item 1 — install_envelope advanced @held_generation before it
# wrote the store. An interrupt part-way through the store write (Thread#raise,
# Timeout on the single-leg path) left a torn store at the NEW generation, so
# the same-generation redelivery that follows (SSE re-sends the current
# envelope on every connect) was ignored and the store was never repaired.
class TestConfigLoaderTornInstall < Minitest::Test
  # A store whose N-th #set raises, standing in for an async interrupt that
  # lands mid-write.
  class InterruptingStore < Quonfig::ConfigStore
    def initialize(raise_on_set:)
      super()
      @raise_on_set = raise_on_set
      @sets = 0
    end

    def set(key, value)
      @sets += 1
      raise Interrupt, 'simulated interrupt mid-install' if @sets == @raise_on_set

      super
    end
  end

  def envelope(gen)
    configs = %w[a b c].map do |k|
      { 'id' => "id-#{k}", 'key' => "torn.#{k}", 'type' => 'config', 'valueType' => 'string',
        'default' => { 'rules' => [] } }
    end
    Quonfig::ConfigEnvelope.new(
      configs: configs,
      meta: { 'version' => "gen-#{gen}", 'environment' => 'production', 'generation' => gen }
    )
  end

  def test_same_generation_redelivery_repairs_a_store_torn_by_an_interrupt
    store = InterruptingStore.new(raise_on_set: 2)
    options = Quonfig::Options.new(sdk_key: '1-test-sdk-key', api_urls: ['http://127.0.0.1:1'],
                                   enable_sse: false, fallback_poll_enabled: false)
    loader = Quonfig::ConfigLoader.new(store, options)

    assert_raises(Interrupt) { loader.apply_envelope(envelope(5)) }
    assert_nil store.get('torn.c'), 'precondition: the interrupted install left the store torn'

    loader.apply_envelope(envelope(5))

    assert_equal %w[torn.a torn.b torn.c], store.keys.sort,
                 'same-generation redelivery must repair the torn store'
  end
end
