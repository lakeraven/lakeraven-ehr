# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CarePlansControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
        CarePlanStore.instance.add(CarePlan.new(
          ien: "cp-1-1", patient_dfn: "1", title: "Type 2 diabetes management plan",
          status: "active", intent: "plan", category: "assess-plan",
          period_start: Date.new(2026, 2, 1),
          author_name: "MARTINEZ,SARAH",
          description: "Comprehensive diabetes care",
          activities: [
            { description: "Metformin 500mg BID", status: "in-progress" },
            { description: "Quarterly HbA1c" }
          ]
        ))
        # A foreign-organization patient's plan: dfn 999999 resolves to no
        # patient the test org (rpms-organization-7819) manages.
        CarePlanStore.instance.add(CarePlan.new(
          ien: "cp-foreign-1", patient_dfn: "999999", title: "Foreign plan",
          status: "active", intent: "plan"
        ))
      end

      teardown do
        teardown_smart_auth
        CarePlanStore.reset_instance!
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
        assert_equal "Metformin 500mg BID", plan.dig("activity", 0, "detail", "description")
        assert_equal "2026-02-01", plan.dig("period", "start")
        assert_equal "active", plan["status"]
        assert_equal "plan", plan["intent"]
      end

      # Guards review finding: pre-fix, every activity was stamped with a
      # status derived from the PLAN's status ("active" -> "in-progress").
      # An activity's status must be its own recorded one, else "unknown".
      test "activity statuses are activity-level, never inferred from the plan" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1" }, headers: @headers
        plan = JSON.parse(response.body)["entry"].first["resource"]
        assert_equal "in-progress", plan.dig("activity", 0, "detail", "status")
        assert_equal "unknown", plan.dig("activity", 1, "detail", "status")
      end

      test "status filter narrows results" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1", status: "completed" }, headers: @headers
        assert_equal 0, JSON.parse(response.body)["total"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/CarePlan", headers: @headers
        assert_response :bad_request
      end

      # Guards review finding: search emitted ids that show could not
      # resolve. Every id a search returns must be readable.
      test "every id returned by search is readable via show" do
        get "/lakeraven-ehr/CarePlan", params: { patient: "1" }, headers: @headers
        ids = JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }
        assert ids.any?

        ids.each do |id|
          get "/lakeraven-ehr/CarePlan/#{id}", headers: @headers
          assert_response :ok
          body = JSON.parse(response.body)
          assert_equal "CarePlan", body["resourceType"]
          assert_equal id, body["id"]
        end
      end

      test "show returns 404 OperationOutcome for an unknown id" do
        get "/lakeraven-ehr/CarePlan/99999", headers: @headers
        assert_response :not_found
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
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

      # Guards review finding: a resolved foreign resource must be a 403
      # (never served, never a masking 404).
      test "org-bound credential gets 403 for a foreign patient's care plan id" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/CarePlan.read")

        get "/lakeraven-ehr/CarePlan/cp-1-1", headers: @headers
        assert_response :ok

        get "/lakeraven-ehr/CarePlan/cp-foreign-1", headers: @headers
        assert_response :forbidden
      end
    end
  end
end
