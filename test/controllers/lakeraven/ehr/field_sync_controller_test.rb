# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FieldSyncControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup { setup_smart_auth(scopes: "system/*.*") }
      teardown { teardown_smart_auth }

      def create_op(id, **payload)
        {
          client_op_id: id, operation_type: "create", target_type: "FieldLabTracking",
          payload: { patient_ref: "panel-1", condition: "HCV", screening_result: "reactive", site_ien: "463" }.merge(payload)
        }
      end

      test "POST /field/sync requires a write scope" do
        teardown_smart_auth
        setup_smart_auth(scopes: "patient/Observation.read")
        post "/lakeraven-ehr/field/sync", params: { operations: [] }, headers: @headers, as: :json
        assert_response :forbidden
      end

      test "POST /field/sync applies a create and returns per-op outcomes" do
        post "/lakeraven-ehr/field/sync",
             params: { batch_id: "b1", operations: [ create_op("op-1") ] },
             headers: @headers, as: :json

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 1, body["summary"]["applied"]
        op = body["operations"].first
        assert_equal "applied", op["outcome"]
        assert op["server_resource_id"].present?
        assert_equal 1, op["server_version"]
      end

      test "POST /field/sync replay reports duplicate without double-applying" do
        post "/lakeraven-ehr/field/sync", params: { operations: [ create_op("op-2") ] }, headers: @headers, as: :json
        post "/lakeraven-ehr/field/sync", params: { operations: [ create_op("op-2") ] }, headers: @headers, as: :json

        body = JSON.parse(response.body)
        assert_equal "duplicate", body["operations"].first["outcome"]
        assert_equal 1, FieldLabTrackingRecord.count
      end

      test "GET /field/work_queue lists follow-ups and unresolved conflicts" do
        post "/lakeraven-ehr/field/sync", params: { operations: [ create_op("op-3", patient_ref: "panel-42") ] },
             headers: @headers, as: :json

        get "/lakeraven-ehr/field/work_queue", params: { site_ien: "463" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert body["follow_ups"].any? { |f| f["patient_ref"] == "panel-42" && f["awaiting"] == "confirmation" }
        assert_kind_of Array, body["conflicts"]
      end

      test "POST /field/sync without a token is unauthorized" do
        post "/lakeraven-ehr/field/sync", params: { operations: [] }, as: :json
        assert_response :unauthorized
      end
    end
  end
end
