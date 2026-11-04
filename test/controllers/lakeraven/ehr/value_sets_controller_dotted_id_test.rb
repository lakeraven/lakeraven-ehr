# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ValueSetsControllerDottedIdTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      OID = "2.16.840.1.113883.3.464.1003.103.12.1001"
      DOTTED_SLUG = "gpra.v1"

      setup do
        setup_smart_auth
        @original_paths = TerminologyService.additional_valueset_paths
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        @original_umls = ENV["UMLS_API_KEY"]
        ENV["TERMINOLOGY_BACKEND"] = nil
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = nil
        Terminology::AdapterFactory.reset_registrations!

        @extra_dir = Dir.mktmpdir("lakeraven-dotted-valuesets")
        write_valueset(@extra_dir, OID, "Synthetic OID ValueSet")
        write_valueset(@extra_dir, DOTTED_SLUG, "Synthetic dotted slug ValueSet")
        TerminologyService.additional_valueset_paths = [ @extra_dir ]
      end

      teardown do
        teardown_smart_auth
        TerminologyService.additional_valueset_paths = @original_paths
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        ENV["UMLS_API_KEY"] = @original_umls
        Terminology::AdapterFactory.reset_registrations!
        FileUtils.remove_entry(@extra_dir) if @extra_dir
      end

      test "GET ValueSet show for OID id in additional_valueset_paths returns 200 ValueSet" do
        get "/lakeraven-ehr/ValueSet/#{OID}", headers: @headers
        assert_response :ok, response.body
        body = JSON.parse(response.body)
        assert_equal "ValueSet", body["resourceType"]
        assert_equal OID, body["id"]
        assert_equal "Synthetic OID ValueSet", body["title"]
      end

      test "GET ValueSet show for id containing a dot returns 200 ValueSet" do
        get "/lakeraven-ehr/ValueSet/#{DOTTED_SLUG}", headers: @headers
        assert_response :ok, response.body
        body = JSON.parse(response.body)
        assert_equal "ValueSet", body["resourceType"]
        assert_equal DOTTED_SLUG, body["id"]
      end

      private

      def write_valueset(directory, id, title)
        File.write(
          File.join(directory, "#{id}.json"),
          {
            resourceType: "ValueSet",
            id: id,
            title: title,
            status: "active",
            compose: {
              include: [
                {
                  system: "http://example.com/synthetic-dotted",
                  concept: [ { code: "SYN-1", display: "Synthetic code" } ]
                }
              ]
            }
          }.to_json
        )
      end
    end
  end
end
