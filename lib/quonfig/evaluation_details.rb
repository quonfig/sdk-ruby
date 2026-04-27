# frozen_string_literal: true

module Quonfig
  # Public details record returned by Quonfig::Client#get_*_details. Surfaces
  # the resolution reason and (on error) an error_code/error_message alongside
  # the resolved value, so downstream layers — most importantly the
  # OpenFeature provider — can map the result without losing fidelity.
  #
  # +reason+ is one of the strings:
  #   "STATIC"           — config has no targeting rules; matched value is the static default
  #   "TARGETING_MATCH"  — a targeting rule matched (any non-ALWAYS_TRUE criterion)
  #   "SPLIT"            — matched value came from a weighted variant
  #   "DEFAULT"          — no rule matched (eval fell through)
  #   "ERROR"            — evaluation failed
  #
  # +error_code+ (only when reason == "ERROR") is one of:
  #   "FLAG_NOT_FOUND" — the key was unknown to the store
  #   "TYPE_MISMATCH"  — the resolved value didn't satisfy the requested type
  #   "GENERAL"        — any other failure
  class EvaluationDetails
    REASON_STATIC          = 'STATIC'
    REASON_TARGETING_MATCH = 'TARGETING_MATCH'
    REASON_SPLIT           = 'SPLIT'
    REASON_DEFAULT         = 'DEFAULT'
    REASON_ERROR           = 'ERROR'

    ERROR_FLAG_NOT_FOUND = 'FLAG_NOT_FOUND'
    ERROR_TYPE_MISMATCH  = 'TYPE_MISMATCH'
    ERROR_GENERAL        = 'GENERAL'

    attr_reader :value, :reason, :error_code, :error_message

    def initialize(value:, reason:, error_code: nil, error_message: nil)
      @value         = value
      @reason        = reason
      @error_code    = error_code
      @error_message = error_message
    end

    def ==(other)
      other.is_a?(EvaluationDetails) &&
        other.value == @value &&
        other.reason == @reason &&
        other.error_code == @error_code &&
        other.error_message == @error_message
    end
    alias eql? ==

    def hash
      [@value, @reason, @error_code, @error_message].hash
    end

    def inspect
      parts = ["value=#{@value.inspect}", "reason=#{@reason.inspect}"]
      parts << "error_code=#{@error_code.inspect}" if @error_code
      parts << "error_message=#{@error_message.inspect}" if @error_message
      "#<Quonfig::EvaluationDetails #{parts.join(' ')}>"
    end
  end
end
