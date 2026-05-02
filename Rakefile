# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.pattern = 'test/**/test_*.rb'
  t.verbose = true
end

task default: :test

desc 'Code coverage detail'
task :simplecov do
  ENV['COVERAGE'] = 'true'
  Rake::Task['test'].execute
end

# Invoked by .github/workflows/release.yml via rubygems/release-gem@v1.
# The workflow has already built the gem and run smoke_check.sh; we just
# push the existing artifact. If the gem file isn't on disk (running this
# locally), build + smoke-check first so the path is the same either way.
desc 'Push the built gem to RubyGems (used by CI release workflow)'
task :release do
  require_relative 'lib/quonfig/version'
  gem_file = "quonfig-#{Quonfig::VERSION}.gem"
  unless File.exist?(gem_file)
    sh "gem build quonfig.gemspec --output #{gem_file}"
    sh "scripts/smoke_check.sh #{gem_file}"
  end
  sh "gem push #{gem_file}"
end
