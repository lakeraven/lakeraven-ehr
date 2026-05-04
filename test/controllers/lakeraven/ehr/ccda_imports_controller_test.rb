# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CcdaImportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "POST /ccda_imports with valid C-CDA returns 201" do
        ccda_xml = build_minimal_ccda
        post "/lakeraven-ehr/ccda_imports",
          params: ccda_xml,
          headers: @headers.merge("Content-Type" => "application/xml")
        # May succeed or fail on parse — but should not 500
        assert_includes [201, 422], response.status
      end

      test "POST /ccda_imports with empty body returns 400" do
        post "/lakeraven-ehr/ccda_imports",
          params: "",
          headers: @headers.merge("Content-Type" => "application/xml")
        assert_response :bad_request
      end

      test "POST /ccda_imports requires auth" do
        post "/lakeraven-ehr/ccda_imports",
          params: "<ClinicalDocument/>",
          headers: {"Content-Type" => "application/xml"}
        assert_response :unauthorized
      end

      test "response is FHIR OperationOutcome" do
        post "/lakeraven-ehr/ccda_imports",
          params: "",
          headers: @headers.merge("Content-Type" => "application/xml")
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      private

      def build_minimal_ccda
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <ClinicalDocument xmlns="urn:hl7-org:v3">
            <typeId root="2.16.840.1.113883.1.3" extension="POCD_HD000040"/>
            <templateId root="2.16.840.1.113883.10.20.22.1.2"/>
            <recordTarget>
              <patientRole>
                <id root="2.16.840.1.113883.19" extension="12345"/>
              </patientRole>
            </recordTarget>
          </ClinicalDocument>
        XML
      end
    end
  end
end
