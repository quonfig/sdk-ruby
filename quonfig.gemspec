# frozen_string_literal: true

require_relative 'lib/quonfig/version'

Gem::Specification.new do |s|
  s.name        = 'quonfig'
  s.version     = Quonfig::VERSION
  s.authors     = ['Jeff Dwyer']
  s.email       = 'jeff@quonfig.com'
  s.summary     = 'Quonfig Ruby SDK'
  s.description = 'Quonfig — feature flags and live config, stored as files in git.'
  s.homepage    = 'https://github.com/quonfig/sdk-ruby'
  s.license     = 'MIT'
  s.required_ruby_version = '>= 3.0'

  s.metadata = {
    'source_code_uri'   => 'https://github.com/quonfig/sdk-ruby',
    'changelog_uri'     => 'https://github.com/quonfig/sdk-ruby/blob/main/CHANGELOG.md',
    'rubygems_mfa_required' => 'true'
  }

  s.require_paths = ['lib']
  s.files = Dir['lib/**/*.rb'] + %w[
    CHANGELOG.md
    LICENSE.txt
    README.md
    quonfig.gemspec
  ]
  s.extra_rdoc_files = %w[CHANGELOG.md LICENSE.txt README.md]

  s.add_runtime_dependency 'activesupport', '>= 4'
  s.add_runtime_dependency 'concurrent-ruby', '~> 1.0', '>= 1.0.5'
  s.add_runtime_dependency 'faraday', '>= 1.0'
  s.add_runtime_dependency 'ld-eventsource', '>= 2.0'
  s.add_runtime_dependency 'uuid', '>= 2.0'
end
