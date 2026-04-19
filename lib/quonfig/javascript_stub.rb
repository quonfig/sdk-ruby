# frozen_string_literal: true

module Quonfig
  class JavaScriptStub
    LOG = Quonfig::InternalLogger.new(self)
    CAMELS = {}

    def initialize(client = nil)
      @client = client || Prefab.instance
    end

    def bootstrap(context)
      configs, warnings = data(context, :bootstrap)
      <<~JS
        window._prefabBootstrap = {
          evaluations: #{JSON.dump(configs)},
          context: #{JSON.dump(context)}
        }
        #{log_warnings(warnings)}
      JS
    end

    def generate_stub(context, callback = nil)
      configs, warnings = data(context, :stub)
      <<~JS
        window.prefab = window.prefab || {};
        window.prefab.config = #{JSON.dump(configs)};
        window.prefab.get = function(key) {
          var value = window.prefab.config[key];
        #{callback && "  #{callback}(key, value);"}
          return value;
        };
        window.prefab.isEnabled = function(key) {
          var value = window.prefab.config[key] === true;
        #{callback && "  #{callback}(key, value);"}
          return value;
        };
        #{log_warnings(warnings)}
      JS
    end

    private

    def underlying_value(value)
      v = Quonfig::ConfigValueUnwrapper.new(value, @client.resolver).unwrap(raw_json: true)
      case v
      when Google::Protobuf::RepeatedField
        v.to_a
      when Quonfig::Duration
        v.as_json
      else
        v
      end
    end

    def log_warnings(warnings)
      return '' if warnings.empty?

      <<~JS
        console.warn('The following keys could not be resolved:', #{JSON.dump(warnings)});
      JS
    end

    def data(context, mode)
      permitted = {}
      warnings = []
      resolver_keys = @client.resolver.keys

      resolver_keys.each do |key|
        begin
          config = @client.resolver.raw(key)

          if config.config_type == :FEATURE_FLAG || config.send_to_client_sdk || config.config_type == :LOG_LEVEL
            value = @client.resolver.get(key, context).value
            if mode == :bootstrap
              permitted[key] = { value: { to_camel_case(value.type) => underlying_value(value) } }
            else
              permitted[key] = underlying_value(value)
            end
          end
        rescue StandardError => e
          LOG.warn("Could not resolve key #{key}: #{e}")

          warnings << key
        end
      end

      [permitted, warnings]
    end

    def to_camel_case(str)
      CAMELS[str] ||= begin
        str.to_s.split('_').map.with_index { |word, index|
          index == 0 ? word : word.capitalize
        }.join
      end
    end
  end
end
