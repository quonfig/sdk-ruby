# frozen_string_literal: true

module Quonfig
  ConfigEnvelope = Struct.new(:configs, :meta, keyword_init: true) do
    # qfg-9dxb.3: true when a decoded wire payload is a config envelope — a
    # Hash carrying a +meta+ object with a non-empty +version+. api-delivery and
    # `qfg serve` always send one; a `{}` or `{"error":"x"}` 200 from a
    # misbehaving proxy/WAF does not, and must never be installed (it would
    # read as "zero configs" and wipe every key on an established client).
    def self.wire_envelope?(data)
      return false unless data.is_a?(Hash)

      meta = data['meta']
      return false unless meta.is_a?(Hash)

      version = meta['version']
      !version.nil? && !version.to_s.empty?
    end
  end
end
