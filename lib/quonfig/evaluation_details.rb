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
  #   "PROVIDER_NOT_READY" — the client has no config yet (init continued
  #                          on code defaults, or a caught init failure)
  #   "GENERAL"        — any other failure
  #
  # +value_type+ is set only by Client#evaluate_details: the stored value
  # type ("string", "int", "double", "bool", "string_list", "duration",
  # "json", ...), or nil when nothing resolved. The typed getters leave it nil.
  class EvaluationDetails
    REASON_STATIC          = 'STATIC'
    REASON_TARGETING_MATCH = 'TARGETING_MATCH'
    REASON_SPLIT           = 'SPLIT'
    REASON_DEFAULT         = 'DEFAULT'
    REASON_ERROR           = 'ERROR'

    ERROR_FLAG_NOT_FOUND = 'FLAG_NOT_FOUND'
    ERROR_TYPE_MISMATCH  = 'TYPE_MISMATCH'
    ERROR_GENERAL        = 'GENERAL'
    ERROR_PROVIDER_NOT_READY = 'PROVIDER_NOT_READY'

    attr_reader :value, :reason, :error_code, :error_message, :variant, :flag_metadata, :value_type

    def initialize(value:, reason:, error_code: nil, error_message: nil,
                   variant: nil, flag_metadata: nil, value_type: nil)
      @value         = value
      @reason        = reason
      @error_code    = error_code
      @error_message = error_message
      @variant       = variant
      @flag_metadata = flag_metadata
      @value_type    = value_type
    end

    def ==(other)
      other.is_a?(EvaluationDetails) &&
        other.value == @value &&
        other.reason == @reason &&
        other.error_code == @error_code &&
        other.error_message == @error_message &&
        other.variant == @variant &&
        other.flag_metadata == @flag_metadata &&
        other.value_type == @value_type
    end
    alias eql? ==

    def hash
      [@value, @reason, @error_code, @error_message, @variant, @flag_metadata, @value_type].hash
    end

    def inspect
      parts = ["value=#{@value.inspect}", "reason=#{@reason.inspect}"]
      parts << "error_code=#{@error_code.inspect}" if @error_code
      parts << "error_message=#{@error_message.inspect}" if @error_message
      parts << "variant=#{@variant.inspect}" if @variant
      parts << "flag_metadata=#{@flag_metadata.inspect}" if @flag_metadata
      parts << "value_type=#{@value_type.inspect}" if @value_type
      "#<Quonfig::EvaluationDetails #{parts.join(' ')}>"
    end
  end
end
