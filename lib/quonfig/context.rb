# frozen_string_literal: true

module Quonfig
  # Quonfig context: a two-level Hash (named-context → property → value) wrapped
  # for evaluator consumption. The Evaluator accepts either a plain Hash or a
  # Quonfig::Context — this class exists mostly to flatten lookups (`get`)
  # into the dotted "context-name.property" form criterion rules use.
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

      def merge!(other)
        other.each { |k, v| @hash[k.to_s] = v }
        self
      end
    end

    attr_reader :contexts

    def initialize(hash = {})
      @contexts = {}
      @flattened = {}

      raise ArgumentError, 'must be a Hash' unless hash.is_a?(Hash)

      hash.each do |name, values|
        unless values.is_a?(Hash)
          # Legacy shorthand — pre-named-contexts callers passed a flat Hash.
          values = { name => values }
          name = BLANK_CONTEXT_NAME
        end

        @contexts[name.to_s] = NamedContext.new(name, values)
        values.each do |key, value|
          @flattened[name.to_s + '.' + key.to_s] = value
        end
      end
    end

    def blank?
      @contexts.empty?
    end

    def set(name, hash)
      @contexts[name.to_s] = NamedContext.new(name, hash)
      hash.each do |key, value|
        @flattened[name.to_s + '.' + key.to_s] = value
      end
    end

    def get(property_key, scope: nil)
      property_key = BLANK_CONTEXT_NAME + '.' + property_key unless property_key.include?('.')
      @flattened[property_key]
    end

    def to_h
      @contexts.transform_values(&:to_h)
    end

    def to_s
      "#<Quonfig::Context:#{object_id} #{to_h}>"
    end

    def clear
      @contexts = {}
      @flattened = {}
    end

    def context(name)
      @contexts[name.to_s] || NamedContext.new(name, {})
    end

    # Concatenate each named context's `key` (or `trackingId`) value into
    # a stable identifier used for example-contexts dedupe. Mirrors
    # sdk-node's groupedKey: contexts that don't have a `key` property
    # contribute nothing — the resulting string is empty for "anonymous"
    # contexts so the example aggregator can drop them entirely.
    def grouped_key
      @contexts.values.map do |ctx|
        h = ctx.to_h
        v = h['key'] || h[:key] || h['trackingId'] || h[:trackingId]
        v.nil? ? nil : v.to_s
      end.compact.reject(&:empty?).sort.join('|')
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
