# frozen_string_literal: true

module Quonfig
  class Context
    BLANK_CONTEXT_NAME = ''

    class NamedContext
      attr_reader :name

      def initialize(name, hash)
        @name = name.to_s
        @hash = hash.transform_keys(&:to_s)
      end

      def to_h
        @hash
      end

      def key
        "#{@name}:#{@hash['key']}"
      end

      def to_proto
        PrefabProto::Context.new(
          type: name,
          values: @hash.transform_values do |value|
            ConfigValueWrapper.wrap(value)
          end
        )
      end
    end

    THREAD_KEY = :prefab_context
    attr_reader :contexts, :seen_at, :id, :parent

    class << self
      def global_context=(context)
        @global_context = join(hash: context, parent: nil, id: :global_context)
      end

      def global_context
        @global_context ||= join(parent: nil, id: :global_context)
      end

      def default_context=(context)
        @default_context = join(hash: context, parent: global_context, id: :default_context)

        self.current.update_parent(@default_context)
      end

      def default_context
        @default_context ||= join(parent: global_context, id: :default_context)
      end

      def current=(context)
        Thread.current[THREAD_KEY] = join(hash: context || {}, parent: default_context, id: :block)
      end

      def current
        Thread.current[THREAD_KEY] ||= join(parent: default_context, id: :block)
      end

      def with_context(context)
        old_context = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = join(parent: default_context, hash: context, id: :block)
        yield
      ensure
        Thread.current[THREAD_KEY] = old_context
      end

      def with_merged_context(context)
        old_context = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = join(parent: current, hash: context, id: :merged)
        yield
      ensure
        Thread.current[THREAD_KEY] = old_context
      end

      def clear_current
        Thread.current[THREAD_KEY] = nil
      end

      def merge_with_current(new_context_properties = {})
        new(current.to_h.merge(new_context_properties.to_h))
      end
    end

    def self.join(hash: {}, parent: nil, id: :not_provided)
      context = new(hash)
      context.update_parent(parent)
      context.instance_variable_set(:@id, id)
      context
    end

    def initialize(hash = {})
      @contexts = {}
      @flattened = {}
      @seen_at = Time.now.utc.to_i

      if hash.is_a?(Hash)
        hash.map do |name, values|
          unless values.is_a?(Hash)
            warn "[DEPRECATION] Prefab contexts should be a hash with a key of the context name and a value of a hash."
            values = { name => values }
            name = BLANK_CONTEXT_NAME
          end

          @contexts[name.to_s] = NamedContext.new(name, values)
          values.each do |key, value|
            @flattened[name.to_s + '.' + key.to_s] = value
          end
        end
      else
        raise ArgumentError, 'must be a Hash'
      end
    end

    def update_parent(parent)
      @parent = parent
    end

    def blank?
      contexts.empty?
    end

    def set(name, hash)
      @contexts[name.to_s] = NamedContext.new(name, hash)
      hash.each do |key, value|
        @flattened[name.to_s + '.' + key.to_s] = value
      end
    end

    def get(property_key, scope: nil)
      if !property_key.include?(".")
        property_key = BLANK_CONTEXT_NAME + '.' + property_key
      end

      if @flattened.key?(property_key)
        @flattened[property_key]
      else
        scope ||= property_key.split('.').first

        if @contexts[scope]
          # If the key is in the present scope, parent values should not be used.
          # We can consider the parent value clobbered by the present scope.
          nil
        else
          @parent&.get(property_key, scope: scope)
        end
      end
    end

    def to_h
      contexts.transform_values(&:to_h)
    end

    def to_s
      "#<Quonfig::Context:#{object_id} id=#{@id} #{to_h}>"
    end

    # Visualize a tree of the context up through its parents
    #
    # example:
    #
    # | jit:                            {"user"=>{"name"=>"Frank"}}
    # |-- block:                        {"clock"=>{"timezone"=>"PST"}}
    # |---- default_context:            {"prefab-api-key"=>{"user-id"=>123}}
    # |------ global_context:           {"cpu"=>{"count"=>4, "speed"=>"2.4GHz"}, "clock"=>{"timezone"=>"UTC"}}
    def tree(depth = 0)
      "|" + ("-" * depth) + " #{id}: #{(" " * (30 - id.to_s.length - depth ))}#{to_h}\n" + (@parent&.tree(depth + 2) || '')
    end

    def clear
      @contexts = {}
      @flattened = {}
    end

    def context(name)
      contexts[name.to_s] || NamedContext.new(name, {})
    end

    def merge_default(defaults)
      defaults.keys.each do |name|
        set(name, context(name).merge!(defaults[name]))
      end

      self
    end

    def reportable_tree
      ctx = self
      reportables = []

      while ctx
        reportables.unshift(ctx)
        ctx = ctx.parent
      end

      reportables
    end

    def to_proto(namespace)
      reportable_contexts = {}

      reportable_tree.each do |ctx|
        ctx.contexts.each do |name, context|
          reportable_contexts[name] = context
        end
      end

      PrefabProto::ContextSet.new(
        contexts: reportable_contexts.map do |name, context|
          context.to_proto
        end
      )
    end

    def slim_proto
      PrefabProto::ContextSet.new(
        contexts: contexts.map do |_, context|
          context.to_proto
        end
      )
    end

    def grouped_key
      contexts.map do |_, context|
        context.key
      end.sort.join('|')
    end

    include Comparable
    def <=>(other)
      if other.is_a?(Quonfig::Context)
        to_h <=> other.to_h
      else
        super
      end
    end
  end
end
