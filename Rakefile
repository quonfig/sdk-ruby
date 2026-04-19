# frozen_string_literal: true

require 'rubygems'
require 'bundler'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  warn e.message
  warn 'Run `bundle install` to install missing gems'
  exit e.status_code
end

require 'rake'

require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
end

task default: :test

unless ENV['CI']
  require 'juwelier'
  Juwelier::Tasks.new do |gem|
    # gem is a Gem::Specification... see http://guides.rubygems.org/specification-reference/ for more options
    gem.name = 'quonfig'
    gem.homepage = 'https://github.com/quonfig/sdk-ruby'
    gem.license = 'MIT'
    gem.summary = %(Quonfig Ruby SDK)
    gem.description = %(Quonfig — feature flags and live config, stored as files in git.)
    gem.email = 'jeff@quonfig.com'
    gem.authors = ['Jeff Dwyer']

    # dependencies defined in Gemfile
  end
  Juwelier::RubygemsDotOrgTasks.new

  desc 'Code coverage detail'
  task :simplecov do
    ENV['COVERAGE'] = 'true'
    Rake::Task['test'].execute
  end

  require 'rdoc/task'
  Rake::RDocTask.new do |rdoc|
    version = File.exist?('VERSION') ? File.read('VERSION') : ''

    rdoc.rdoc_dir = 'rdoc'
    rdoc.title = "quonfig #{version}"
    rdoc.rdoc_files.include('README*')
    rdoc.rdoc_files.include('lib/**/*.rb')
  end
end

# Add release task for CI
task :release do
  sh 'mkdir -p pkg'
  version = File.read('VERSION').strip
  gem_file = "pkg/quonfig-#{version}.gem"
  sh "gem build quonfig.gemspec --output #{gem_file}"
  sh "gem push #{gem_file}"
end
