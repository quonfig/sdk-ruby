# frozen_string_literal: true

require 'test_helper'

class TestLoggerInitialization < Minitest::Test

  def test_init_out_of_order
    # assert nothing blows up
    Quonfig.log_filter
  end

end
