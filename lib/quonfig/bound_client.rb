# frozen_string_literal: true

module Quonfig
  # Immutable context-bound view over a Quonfig::Client. Every lookup uses the
  # bound context as the jit_context passed down to the resolver.
  class BoundClient
    attr_reader :client, :context

    def initialize(client, context)
      @client = client
      @context = context || {}
      freeze
    end

    def get_string(key, default: NO_DEFAULT_PROVIDED)
      @client.get_string(key, default: default, context: @context)
    end

    def get_int(key, default: NO_DEFAULT_PROVIDED)
      @client.get_int(key, default: default, context: @context)
    end

    def get_float(key, default: NO_DEFAULT_PROVIDED)
      @client.get_float(key, default: default, context: @context)
    end

    def get_bool(key, default: NO_DEFAULT_PROVIDED)
      @client.get_bool(key, default: default, context: @context)
    end

    def get_string_list(key, default: NO_DEFAULT_PROVIDED)
      @client.get_string_list(key, default: default, context: @context)
    end

    def get_duration(key, default: NO_DEFAULT_PROVIDED)
      @client.get_duration(key, default: default, context: @context)
    end

    def get_json(key, default: NO_DEFAULT_PROVIDED)
      @client.get_json(key, default: default, context: @context)
    end

    # ---- Details getters ----------------------------------------------

    def get_bool_details(key)
      @client.get_bool_details(key, context: @context)
    end

    def get_string_details(key)
      @client.get_string_details(key, context: @context)
    end

    def get_int_details(key)
      @client.get_int_details(key, context: @context)
    end

    def get_float_details(key)
      @client.get_float_details(key, context: @context)
    end

    def get_string_list_details(key)
      @client.get_string_list_details(key, context: @context)
    end

    def get_json_details(key)
      @client.get_json_details(key, context: @context)
    end

    def enabled?(feature_name)
      @client.enabled?(feature_name, @context)
    end

    # Returns a new BoundClient whose bound context is the merge of this
    # bound context and +additional+. Merge is one level deep per named
    # context (mirrors sdk-node's mergeContexts): later values override
    # earlier within the same named context; keys unique to each side are
    # preserved.
    def in_context(additional)
      self.class.new(@client, merge_contexts(@context, additional || {}))
    end

    def inspect
      "#<Quonfig::BoundClient context=#{@context.inspect}>"
    end

    private

    def merge_contexts(left, right)
      merged = {}
      left.each  { |name, ctx| merged[name] = ctx.dup }
      right.each do |name, ctx|
        merged[name] = merged[name] ? merged[name].merge(ctx) : ctx.dup
      end
      merged
    end
  end
end
