module Quonfig
  class ConfigValueWrapper
    def self.wrap(value, confidential: nil)
      case value
      when Integer
        PrefabProto::ConfigValue.new(int: value, confidential: confidential)
      when Float
        PrefabProto::ConfigValue.new(double: value, confidential: confidential)
      when TrueClass, FalseClass
        PrefabProto::ConfigValue.new(bool: value, confidential: confidential)
      when Array
        PrefabProto::ConfigValue.new(string_list: PrefabProto::StringList.new(values: value.map(&:to_s)), confidential: confidential)
      else
        PrefabProto::ConfigValue.new(string: value.to_s, confidential: confidential)
      end
    end
  end
end
