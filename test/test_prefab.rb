# frozen_string_literal: true

require 'test_helper'

class TestPrefab < Minitest::Test



  private

  def init_once
    unless Quonfig.instance_variable_get("@singleton")
      Quonfig.init(prefab_options)
    end
  end
end
