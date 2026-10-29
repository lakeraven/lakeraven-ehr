# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ValueSetsControllerPathTraversalTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        @original_umls = ENV["UMLS_API_KEY"]
        ENV["TERMINOLOGY_BACKEND"] = nil
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = nil
        Terminology::AdapterFactory.reset_registrations!

        @leak_dir = Dir.mktmpdir("lakeraven-valueset-leak")
        @leak_json = File.join(@leak_dir, "LEAKED.json")
        File.write(
          @leak_json,
          {
            resourceType: "ValueSet",
            id: "LEAKED",
            title: "Leaked ValueSet",
            status: "active",
            compose: {
              include: [
                {
                  system: "http://example.com/leaked",
                  concept: [ { code: "LEAKED-CODE", display: "Leaked code" } ]
                }
              ]
            }
          }.to_json
        )
        @leak_id = @leak_json.delete_suffix(".json")
      end

      teardown do
        teardown_smart_auth
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        ENV["UMLS_API_KEY"] = @original_umls
        Terminology::AdapterFactory.reset_registrations!
        FileUtils.remove_entry(@leak_dir) if @leak_dir
      end

      test "GET ValueSet with url-encoded absolute path outside valueset dirs returns not-found without leaking content" do
        get "/lakeraven-ehr/ValueSet/#{CGI.escape(@leak_id)}", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
        refute_includes response.body, "LEAKED"
      end

      test "GET ValueSet expand with url-encoded relative traversal returns not-found without leaking content" do
        get "/lakeraven-ehr/ValueSet/#{CGI.escape('../../..')}/$expand",
          headers: @headers.merge("Accept" => "application/fhir+json")
        assert_response :not_found
        refute_includes response.body, "LEAKED"
        assert_equal "application/fhir+json", response.media_type,
                     "Traversal id must reach ValueSet#expand and answer with FHIR JSON, not a generic HTML 404"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end
    end
  end
end
