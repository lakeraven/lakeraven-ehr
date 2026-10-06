# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # GATE SPEC — ORHC Booth Demo Spec v1.1 §5 (X-Request-Id / SSP-27).
    class RequestIdCorrelationTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        # Org-bound system token (default site 7819 / Patient 1) — unbound tokens are
        # refused before the request reaches X-Request-Id handling.
        setup_smart_auth(scopes: "system/Patient.read")
      end

      teardown do
        teardown_smart_auth
      end

      # Catches middleware/controller that drops inbound correlation ids.
      test "inbound X-Request-Id is echoed on the FHIR response" do
        inbound = "orhc-gate-correlation-7f3a2b1c"
        get "/lakeraven-ehr/Patient/1",
          headers: @headers.merge("X-Request-Id" => inbound)

        assert_response :ok
        assert_equal inbound, response.headers["X-Request-Id"],
          "screen capture correlation requires echoing the inbound request id"
      end

      # Catches responses with no correlation header when the client omits one.
      test "absent X-Request-Id receives a generated response header" do
        get "/lakeraven-ehr/Patient/1", headers: @headers

        assert_response :ok
        generated = response.headers["X-Request-Id"]
        refute generated.blank?, "must generate X-Request-Id when the client sends none"
        assert_match(/\A[0-9a-f-]{36}\z/i, generated,
          "generated ids should be UUID-shaped for log correlation")
      end
    end
  end
end
