# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BulkExportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /bulk-export-files/:id/:file returns 404 for nonexistent export" do
        get "/lakeraven-ehr/bulk-export-files/nonexistent/data.ndjson", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "GET /$export-status/:id returns 404 for nonexistent export" do
        get "/lakeraven-ehr/$export-status/nonexistent", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "GET /$export-status returns 403 for different client export" do
        get "/lakeraven-ehr/$export-status/other-client-export", headers: @headers
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "DELETE /$export-status/:id returns 404 for nonexistent export" do
        delete "/lakeraven-ehr/$export-status/nonexistent", headers: @headers
        assert_response :not_found
      end

      test "bulk export download requires auth" do
        get "/lakeraven-ehr/bulk-export-files/test/data.ndjson"
        assert_response :unauthorized
      end

      test "export status requires auth" do
        get "/lakeraven-ehr/$export-status/test"
        assert_response :unauthorized
      end

      test "export cancel requires auth" do
        delete "/lakeraven-ehr/$export-status/test"
        assert_response :unauthorized
      end

      test "404 response includes FHIR content type" do
        get "/lakeraven-ehr/$export-status/nonexistent", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "403 response includes error diagnostics" do
        get "/lakeraven-ehr/$export-status/other-client-export", headers: @headers
        body = JSON.parse(response.body)
        assert body["issue"].first["diagnostics"].include?("different client")
      end

      test "expired token returns 401 on download" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/bulk-export-files/test/data.ndjson",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end
    end
  end
end
