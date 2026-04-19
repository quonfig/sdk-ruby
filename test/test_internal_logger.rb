# frozen_string_literal: true

require 'test_helper'

class TestInternalLogger < Minitest::Test

  def test_levels
    logger_a = Quonfig::InternalLogger.new(A)
    logger_b = Quonfig::InternalLogger.new(B)

    assert_equal :warn, logger_a.level
    assert_equal :warn, logger_b.level

    Quonfig::InternalLogger.using_quonfig_log_filter!
    assert_equal :trace, logger_a.level
    assert_equal :trace, logger_b.level
  end

end

class A
end

class B
end
