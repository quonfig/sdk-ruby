# frozen_string_literal: true

module Quonfig
  class ResolvedConfigPresenter
    class ConfigRow
      include Comparable

      attr_reader :key, :value, :match, :source

      def initialize(key, value, match, source)
        @key = key
        @value = value
        @match = match
        @source = source
      end

      def <=>(other)
        inspect <=> other.inspect
      end

      def inspect
        [@key, @value, @match, @source].inspect
      end
    end

    def initialize(resolver, lock, local_store)
      @resolver = resolver
      @lock = lock
      @local_store = local_store
    end

    def each(&block)
      to_h.each(&block)
    end

    def to_h
      hash = {}

      Quonfig::Context.with_context({}) do
        @lock.with_read_lock do
          @local_store.keys.sort.each do |k|
            v = @local_store[k]

            if v.nil?
              hash[k] = ConfigRow.new(k, nil, nil, nil)
            else
              value = @resolver.evaluate(v[:config])&.reportable_value
              hash[k] = ConfigRow.new(k, value, v[:match], v[:source])
            end
          end
        end
      end

      hash
    end

    def to_s
      str = "\n"

      Quonfig::Context.with_context({}) do
        @lock.with_read_lock do
          @local_store.keys.sort.each do |k|
            v = @local_store[k]
            elements = [k.slice(0..49).ljust(50)]
            if v.nil?
              elements << 'tombstone'
            else
              value = begin
                @resolver.evaluate(v[:config])&.reportable_value
              rescue StandardError => e
                "ERROR EVALUATING: #{e.class} #{e.message}"
              end
              elements << value.to_s.slice(0..34).ljust(35)
              elements << value.class.to_s.slice(0..6).ljust(7)
              elements << "Match: #{v[:match]}".slice(0..29).ljust(30)
              elements << "Source: #{v[:source]}"
            end
            str += elements.join(' | ') << "\n"
          end
        end
      end

      str
    end
  end
end
