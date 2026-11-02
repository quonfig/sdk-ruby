# frozen_string_literal: true

source 'https://rubygems.org'

gem 'concurrent-ruby', '~> 1.3'
gem 'faraday', '~> 1.10.5'
gem 'listen', '~> 3.10'

gem 'activesupport', '>= 4'

group :development do
  gem 'allocation_stats'
  gem 'benchmark-ips'
  gem 'brakeman'
  gem 'bundler'
  gem 'bundler-audit'
  # parallel 2.x requires Ruby >= 3.3 — pin to 1.x while the matrix
  # still includes 3.2 (rubocop pulls parallel transitively).
  gem 'parallel', '< 2.0'
  gem 'rake'
  gem 'rdoc'
  gem 'rubocop'
  gem 'simplecov', '>= 0'
end

group :test do
  gem 'minitest', '< 7'
  gem 'minitest-focus'
  # minitest 6 moved minitest/mock into its own gem; the suite uses it.
  gem 'minitest-mock'
  gem 'minitest-reporters'
  gem 'semantic_logger', '!= 4.16.0', require: 'semantic_logger/sync'
  gem 'timecop'
  gem 'webrick'
end
