# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TestSessionsControllerTest < ActiveSupport::TestCase
      test "environment gate raises outside the test environment" do
        controller = TestSessionsController.new
        original_env = Rails.env
        Rails.env = "production"
        assert_raises(ActionController::RoutingError) do
          controller.send(:ensure_test_environment!)
        end
      ensure
        Rails.env = original_env
      end

      test "environment gate passes in the test environment" do
        controller = TestSessionsController.new
        assert_nil controller.send(:ensure_test_environment!)
      end

      test "security keys normalize identically for arrays and strings" do
        controller = TestSessionsController.new
        expected = %w[PROVIDER ORES]
        assert_equal expected,
                     controller.send(:normalized_security_keys, [ " PROVIDER ", "ORES", " ", nil ])
        assert_equal expected,
                     controller.send(:normalized_security_keys, " PROVIDER , ORES ,, ")
        assert_equal [], controller.send(:normalized_security_keys, nil)
      end
    end
  end
end
