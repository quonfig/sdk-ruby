require 'yaml'

module Quonfig
  class YAMLConfigParser
    LOG = Quonfig::InternalLogger.new(self)

    def initialize(file, client)
      @file = file
      @client = client
    end

    def merge(config)
      yaml = load

      yaml.each do |k, v|
        config = Quonfig::LocalConfigParser.parse(k, v, config, @file)
      end

      config
    end

    private

    def load
      if File.exist?(@file)
        LOG.info "Load #{@file}"
        YAML.load_file(@file)
      else
        LOG.info "No file #{@file}"
        {}
      end
    end
  end
end
