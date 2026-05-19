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
    'source_code_uri' => 'https://github.com/quonfig/sdk-ruby',
    'changelog_uri' => 'https://github.com/quonfig/sdk-ruby/blob/main/CHANGELOG.md',
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

  s.add_dependency 'activesupport', '>= 4'
  s.add_dependency 'concurrent-ruby', '~> 1.0', '>= 1.0.5'
  s.add_dependency 'faraday', '>= 1.0'
  # File watching for opt-in data_dir_auto_reload (qfg-mol-2da). 3.x supports
  # Ruby 3.0+. Native backends (rb-fsevent on macOS, rb-inotify on Linux) are
  # transitive deps of `listen`; the polling fallback is used elsewhere.
  s.add_dependency 'listen', '~> 3.8'
end
