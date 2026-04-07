# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHRTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert Lakeraven::EHR::VERSION
  end

  test "version is 0.1.0" do
    assert_equal "0.1.0", Lakeraven::EHR::VERSION
  end
end
