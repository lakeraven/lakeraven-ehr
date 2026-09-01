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

      def auth_headers(scopes:, resource_owner_id: nil)
        app = Doorkeeper::Application.create!(
          name: "t-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/callback",
          scopes: scopes, confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: app, scopes: scopes, resource_owner_id: resource_owner_id, expires_in: 3600
        )
        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      test "POST /field/sync requires a write scope" do
        teardown_smart_auth
        setup_smart_auth(scopes: "patient/Observation.read")
        post "/lakeraven-ehr/field/sync", params: { operations: [] }, headers: @headers, as: :json
        assert_response :forbidden
      end

      test "POST /field/sync rejects a patient/*.* wildcard scope" do
        teardown_smart_auth
        setup_smart_auth(scopes: "patient/*.*")
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

      test "POST /field/sync replay preserves the original outcome and flags a duplicate" do
        post "/lakeraven-ehr/field/sync", params: { operations: [ create_op("op-2") ] }, headers: @headers, as: :json
        post "/lakeraven-ehr/field/sync", params: { operations: [ create_op("op-2") ] }, headers: @headers, as: :json

        body = JSON.parse(response.body)
        op = body["operations"].first
        assert_equal "applied", op["outcome"], "the real persisted outcome is preserved"
        assert_equal true, op["duplicate"], "a replay is flagged so unresolved outcomes aren't masked"
        assert_equal 1, FieldLabTrackingRecord.count
        assert_equal 1, body["summary"]["duplicate"]
      end

      test "POST /field/sync stamps the token clinician, not a caller-supplied DUZ" do
        headers = auth_headers(scopes: "user/*.write site/463", resource_owner_id: 777)
        post "/lakeraven-ehr/field/sync",
             params: { operations: [ create_op("op-duz", clinician_duz: "evil-999") ] },
             headers: headers, as: :json
        assert_response :ok

        assert_equal "777", FieldLabTrackingRecord.last.clinician_duz
        assert_equal "777", FieldSyncOperation.find_by(client_op_id: "op-duz").clinician_duz
      end

      test "GET /field/work_queue without site_ien does not dump all sites" do
        get "/lakeraven-ehr/field/work_queue", headers: @headers
        assert_response :forbidden
      end

      test "GET /field/work_queue rejects a site the token is not authorized for" do
        headers = auth_headers(scopes: "user/*.write site/463")
        get "/lakeraven-ehr/field/work_queue", params: { site_ien: "999" }, headers: headers
        assert_response :forbidden
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
