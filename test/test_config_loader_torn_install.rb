# frozen_string_literal: true

require 'test_helper'

# qfg-goi1.10.2 item 1 — install_envelope advanced @held_generation before it
# wrote the store. An interrupt part-way through the store write (Thread#raise,
# Timeout on the single-leg path) left a torn store at the NEW generation, so
# the same-generation redelivery that follows (SSE re-sends the current
# envelope on every connect) was ignored and the store was never repaired.
class TestConfigLoaderTornInstall < Minitest::Test
  # A store whose N-th #replace_all raises, standing in for an async
  # interrupt that lands during the store write. Since qfg-i86q the write is
  # one atomic swap, so the interrupt leaves the store on the old set (never
  # a torn mix); the generation must still not advance.
  class InterruptingStore < Quonfig::ConfigStore
    def initialize(raise_on_replace:)
      super()
      @raise_on_replace = raise_on_replace
      @replaces = 0
    end

    def replace_all(configs)
      @replaces += 1
      raise Interrupt, 'simulated interrupt mid-install' if @replaces == @raise_on_replace

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
    store = InterruptingStore.new(raise_on_replace: 1)
    options = Quonfig::Options.new(sdk_key: '1-test-sdk-key', api_urls: ['http://127.0.0.1:1'],
                                   enable_sse: false, fallback_poll_enabled: false)
    loader = Quonfig::ConfigLoader.new(store, options)

    assert_raises(Interrupt) { loader.apply_envelope(envelope(5)) }
    assert_empty store.keys, 'precondition: the interrupted install left the store on the old (empty) set'

    loader.apply_envelope(envelope(5))

    assert_equal %w[torn.a torn.b torn.c], store.keys.sort,
                 'same-generation redelivery must install after an interrupted write'
  end
end
