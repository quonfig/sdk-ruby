# frozen_string_literal: true

module Quonfig
  ConfigEnvelope = Struct.new(:configs, :meta, keyword_init: true)
end
