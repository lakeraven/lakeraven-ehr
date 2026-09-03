# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CarePlansControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
        RpmsRpc.client.seed_keyed_collection(:care_plan_list, "1", [
          { ien: "cp-1-1", title: "Type 2 diabetes management plan",
            status: "active", intent: "plan", category: "assess-plan",
            start_date: Date.new(2026, 2, 1), end_date: nil,
            author_duz: "101", author_name: "MARTINEZ,SARAH", goal_iens: "",
            activity: "Metformin 500mg BID; Quarterly HbA1c",
            description: "Comprehensive diabetes care", note: "" }
        ])
      end

      teardown do
        teardown_smart_auth
        RpmsRpc.client.seed_keyed_collection(:care_plan_list, "1", [])
      end

      test "GET /CarePlan?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal 1, body["total"]
        assert_equal "CarePlan", body["entry"].first.dig("resource", "resourceType")
      end

      test "care plans carry category, activity, and period" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1" }, headers: @headers
        plan = JSON.parse(response.body)["entry"].first["resource"]
        assert_equal "assess-plan", plan.dig("category", 0, "coding", 0, "code")
        assert_equal 2, plan["activity"].length
        assert_equal "in-progress", plan.dig("activity", 0, "detail", "status")
        assert_equal "Metformin 500mg BID", plan.dig("activity", 0, "detail", "description")
        assert_equal "2026-02-01", plan.dig("period", "start")
        assert_equal "active", plan["status"]
        assert_equal "plan", plan["intent"]
      end

      test "status filter narrows results" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1", status: "completed" }, headers: @headers
        assert_equal 0, JSON.parse(response.body)["total"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/CarePlan", headers: @headers
        assert_response :bad_request
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/CarePlan/99999", headers: @headers
        assert_response :not_found
      end

      test "requires auth" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1" }
        assert_response :unauthorized
      end

      test "org-bound system credential reads its own organization's patient" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/CarePlan.read")
        get "/lakeraven-ehr/CarePlan", params: { patient: "1" }, headers: @headers
        assert_response :ok
      end
    end
  end
end
