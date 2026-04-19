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

    def enabled?(feature_name)
      @client.enabled?(feature_name, @context)
    end

    def inspect
      "#<Quonfig::BoundClient context=#{@context.inspect}>"
    end
  end
end
