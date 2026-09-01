# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ExportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
        ExportsController.reset_store!
      end

      teardown do
        teardown_smart_auth
        ExportsController.reset_store!
      end

      test "POST /exports creates an export and returns 202" do
        post "/lakeraven-ehr/exports", headers: @headers
        assert_response :accepted
      end

      test "GET /exports/:id returns 404 for nonexistent export" do
        get "/lakeraven-ehr/exports/nonexistent", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "GET /exports/:id returns export status" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
        # 200 = completed, 202 = processing, 500 = failed (no test patient data)
        assert_includes [ 200, 202, 500 ], response.status
      end

      test "DELETE /exports/:id cancels export" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        delete "/lakeraven-ehr/exports/#{export_id}", headers: @headers
        assert_response :accepted
      end

      test "DELETE /exports/:id returns 404 for nonexistent" do
        delete "/lakeraven-ehr/exports/nonexistent", headers: @headers
        assert_response :not_found
      end

      test "exports require auth" do
        post "/lakeraven-ehr/exports"
        assert_response :unauthorized
      end

      test "export status requires auth" do
        get "/lakeraven-ehr/exports/test"
        assert_response :unauthorized
      end

      test "export cancel requires auth" do
        delete "/lakeraven-ehr/exports/test"
        assert_response :unauthorized
      end

      test "completed export shows output files" do
        export = BulkExport.new(
          id: "completed-export",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_COMPLETED,
          request_url: "http://example.org/lakeraven-ehr/exports/completed-export",
          output_format: "application/fhir+ndjson",
          client_id: @oauth_app.uid
        )
        export.set_defaults!
        export.complete!([
          {
            "type" => "Patient",
            "url" => "/lakeraven-ehr/bulk-export-files/completed-export/Patient.ndjson",
            "count" => 1,
            "file_name" => "Patient.ndjson",
            "content" => '{"resourceType":"Patient"}'
          }
        ])
        ExportsController.store["completed-export"] = export

        get "/lakeraven-ehr/exports/completed-export", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert body.key?("output"), "Expected output in completed export"
        assert body.key?("transactionTime")
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        post "/lakeraven-ehr/exports",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "GET /\$export-status/:id returns export status" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/$export-status/#{export_id}", headers: @headers
        assert_includes [ 200, 202, 500 ], response.status
      end

      test "GET /\$export-status/:id requires auth" do
        get "/lakeraven-ehr/$export-status/test"
        assert_response :unauthorized
      end

      test "GET /\$export-status/:id returns 403 for different client" do
        other_app = Doorkeeper::Application.create!(
          name: "other-client", redirect_uri: "https://other.test/callback",
          scopes: "system/*.read", confidential: true
        )
        export = BulkExport.new(
          id: "other-export",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_COMPLETED,
          request_url: "http://example.org/lakeraven-ehr/$export-status/other-export",
          output_format: "application/fhir+ndjson",
          client_id: other_app.uid
        )
        export.set_defaults!
        export.complete!([])
        ExportsController.store["other-export"] = export

        get "/lakeraven-ehr/$export-status/other-export", headers: @headers
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "Export belongs to a different client", body["issue"].first["diagnostics"]
      end

      test "DELETE /\$export-status/:id cancels export" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        delete "/lakeraven-ehr/$export-status/#{export_id}", headers: @headers
        assert_response :accepted
      end

      test "DELETE /\$export-status/:id requires auth" do
        delete "/lakeraven-ehr/$export-status/test"
        assert_response :unauthorized
      end

      test "DELETE /\$export-status/:id returns 403 for different client" do
        other_app = Doorkeeper::Application.create!(
          name: "other-client", redirect_uri: "https://other.test/callback",
          scopes: "system/*.read", confidential: true
        )
        export = BulkExport.new(
          id: "other-export",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_COMPLETED,
          request_url: "http://example.org/lakeraven-ehr/$export-status/other-export",
          output_format: "application/fhir+ndjson",
          client_id: other_app.uid
        )
        export.set_defaults!
        ExportsController.store["other-export"] = export

        delete "/lakeraven-ehr/$export-status/other-export", headers: @headers
        assert_response :forbidden
      end
    end

    class ExportFilesControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
        ExportsController.reset_store!
      end

      teardown do
        teardown_smart_auth
        ExportsController.reset_store!
      end

      def seed_completed_export(export_id, client_id: @oauth_app.uid)
        export = BulkExport.new(
          id: export_id,
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_COMPLETED,
          request_url: "http://example.org/lakeraven-ehr/exports/#{export_id}",
          output_format: "application/fhir+ndjson",
          client_id: client_id
        )
        export.set_defaults!
        export.complete!([
          {
            "type" => "Patient",
            "url" => "/lakeraven-ehr/bulk-export-files/#{export_id}/Patient.ndjson",
            "count" => 1,
            "file_name" => "Patient.ndjson",
            "content" => '{"resourceType":"Patient"}'
          }
        ])
        ExportsController.store[export_id] = export
        export
      end

      test "GET /exports/:id/files/:name returns file content" do
        export = BulkExport.new(
          id: "completed-export",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_COMPLETED,
          request_url: "http://example.org/lakeraven-ehr/exports/completed-export",
          output_format: "application/fhir+ndjson",
          client_id: @oauth_app.uid
        )
        export.set_defaults!
        export.complete!([
          {
            "type" => "Patient",
            "url" => "/lakeraven-ehr/exports/completed-export/files/Patient.ndjson",
            "count" => 1,
            "file_name" => "Patient.ndjson",
            "content" => '{"resourceType":"Patient"}'
          }
        ])
        ExportsController.store["completed-export"] = export

        get "/lakeraven-ehr/exports/completed-export/files/Patient.ndjson", headers: @headers
        assert_response :ok
        assert_equal "application/fhir+ndjson", response.media_type
      end

      test "GET /exports/:id/files/:name returns 404 for nonexistent export" do
        get "/lakeraven-ehr/exports/nonexistent/files/data.ndjson", headers: @headers
        assert_response :not_found
      end

      test "GET /exports/:id/files/:name returns 404 for nonexistent file" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/exports/#{export_id}/files/nonexistent.ndjson", headers: @headers
        assert_response :not_found
      end

      test "export files require auth" do
        get "/lakeraven-ehr/exports/test/files/data.ndjson"
        assert_response :unauthorized
      end

      test "GET /bulk-export-files/:export_id/:file_name returns file content" do
        seed_completed_export("export-1")

        get "/lakeraven-ehr/bulk-export-files/export-1/Patient.ndjson", headers: @headers
        assert_response :ok
        assert_equal "application/fhir+ndjson", response.media_type
      end

      test "GET /bulk-export-files/:export_id/:file_name returns 404 for nonexistent export" do
        get "/lakeraven-ehr/bulk-export-files/nonexistent/Patient.ndjson", headers: @headers
        assert_response :not_found
      end

      test "GET /bulk-export-files/:export_id/:file_name returns 404 for nonexistent file" do
        seed_completed_export("export-1")

        get "/lakeraven-ehr/bulk-export-files/export-1/Nonexistent.ndjson", headers: @headers
        assert_response :not_found
      end

      test "bulk export file download requires auth" do
        get "/lakeraven-ehr/bulk-export-files/export-1/Patient.ndjson"
        assert_response :unauthorized
      end

      test "bulk export file download returns 403 for different client" do
        other_app = Doorkeeper::Application.create!(
          name: "other-client", redirect_uri: "https://other.test/callback",
          scopes: "system/*.read", confidential: true
        )
        seed_completed_export("other-export", client_id: other_app.uid)

        get "/lakeraven-ehr/bulk-export-files/other-export/Patient.ndjson", headers: @headers
        assert_response :forbidden
      end

      test "bulk export file download returns 403 for patient scope" do
        patient_app = Doorkeeper::Application.create!(
          name: "patient-client", redirect_uri: "https://patient.test/callback",
          scopes: "patient/Observation.read", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: patient_app, scopes: "patient/Observation.read", expires_in: 3600
        )
        headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        seed_completed_export("export-1")

        get "/lakeraven-ehr/bulk-export-files/export-1/Patient.ndjson", headers: headers
        assert_response :forbidden
      end
    end
  end
end
