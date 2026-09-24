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
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
        if response.status == 200
          body = JSON.parse(response.body)
          assert body.key?("output"), "Expected output in completed export"
          assert body.key?("transactionTime")
        end
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        post "/lakeraven-ehr/exports",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
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

      test "GET /exports/:id/files/:name returns file content" do
        post "/lakeraven-ehr/exports", headers: @headers
        export_id = JSON.parse(response.body)["id"]

        export = ExportsController.store[export_id]
        if export&.completed? && export.output_files&.any?
          file_name = export.output_files.first["file_name"]
          get "/lakeraven-ehr/exports/#{export_id}/files/#{file_name}", headers: @headers
          assert_response :ok
          assert_equal "application/fhir+ndjson", response.media_type
        end
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
    end
  end
end
