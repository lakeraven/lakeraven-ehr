# frozen_string_literal: true

require "test_helper"

module Lakeraven
  class EHRTest < ActiveSupport::TestCase
    test "it has a version number" do
      assert Lakeraven::EHR::VERSION
    end
  end
end
