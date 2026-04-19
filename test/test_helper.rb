# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/focus'
require 'minitest/reporters'
Minitest::Reporters.use! unless ENV['RM_INFO']

require 'quonfig'

Dir.glob(File.join(File.dirname(__FILE__), 'support', '**', '*.rb')).each do |file|
  require file
end

Minitest::Test.class_eval do
  include CommonHelpers
  extend CommonHelpers
end
