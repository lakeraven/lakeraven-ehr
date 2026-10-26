# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Test-only probe: two separate rate_limit macros on one controller (#498).
    class RateLimitDualDeclarationProbeController < ApplicationController
      class << self
        def install_rate_limit_declarations!
          return if @rate_limit_declarations_installed

          rate_limit only: :a
          rate_limit only: :b
          @rate_limit_declarations_installed = true
        end
      end

      def a
        head :ok
      end

      def b
        head :ok
      end
    end
  end
end

# lakeraven-ehr#498: controllers may declare rate_limit more than once; each
# action group must still enforce independently.
class RateLimitDualDeclarationTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  PROBE_PATH_A = "/lakeraven-ehr/_rate_limit_dual_declaration_probe/a"
  PROBE_PATH_B = "/lakeraven-ehr/_rate_limit_dual_declaration_probe/b"

  setup do
    Lakeraven::EHR::RateLimitDualDeclarationProbeController.install_rate_limit_declarations!
    Lakeraven::EHR::Engine.routes.draw do
      get "_rate_limit_dual_declaration_probe/a", to: "rate_limit_dual_declaration_probe#a"
      get "_rate_limit_dual_declaration_probe/b", to: "rate_limit_dual_declaration_probe#b"
    end
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::Engine.routes.clear!
    load Lakeraven::EHR::Engine.root.join("config/routes.rb")
    reset_rate_limit_declarations!
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "two rate_limit declarations on one controller enforce both action groups" do
    with_test_rate_limit(max_requests: 0, window: 5.minutes) do
      get PROBE_PATH_A, headers: @headers,
          env: integration_request_env(remote_addr: "198.51.100.210")
      assert_response :too_many_requests,
                       "probe action a must be throttled by its rate_limit declaration (#498)"

      get PROBE_PATH_B, headers: @headers,
          env: integration_request_env(remote_addr: "198.51.100.211")
      assert_response :too_many_requests,
                       "probe action b must be throttled by its rate_limit declaration (#498)"
    end
  end
end
