# frozen_string_literal: true

require 'bundler/setup'

gemspec = Dir.glob(File.expand_path("../../*.gemspec", __FILE__)).first
spec = Gem::Specification.load(gemspec)

# Add the require paths to the $LOAD_PATH
spec.require_paths.each do |path|
  full_path = File.expand_path("../" + path, __dir__)
  $LOAD_PATH.unshift(full_path) unless $LOAD_PATH.include?(full_path)
end

spec.require_paths.each do |path|
  require "./lib/quonfig"
end

SemanticLogger.add_appender(io: $stdout)
