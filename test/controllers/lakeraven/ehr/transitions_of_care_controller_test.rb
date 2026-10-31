# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TransitionsOfCareControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        # These endpoints CHANGE STATE, so they need a write scope; the
        # read-as-POST ones need read as well. They used to pass on the default
        # read-only token because the base filter called can_read? for every
        # verb — the tests were encoding the defect.
        setup_smart_auth(scopes: "system/*.read system/*.write")
      end

      teardown do
        teardown_smart_auth
      end

      test "POST /transitions_of_care generates C-CDA XML" do
        post "/lakeraven-ehr/transitions_of_care",
          params: { patient_dfn: "1" }, headers: @headers
        assert_response :created
        assert_equal "application/xml", response.media_type
        assert_includes response.body, "ClinicalDocument"
      end

      test "POST /transitions_of_care returns 404 for unknown patient" do
        post "/lakeraven-ehr/transitions_of_care",
          params: { patient_dfn: "99999" }, headers: @headers
        assert_response :not_found
      end

      test "POST /transitions_of_care includes patient demographics" do
        post "/lakeraven-ehr/transitions_of_care",
          params: { patient_dfn: "1" }, headers: @headers
        assert_includes response.body, "recordTarget"
        assert_includes response.body, "patientRole"
      end

      test "POST /transitions_of_care requires auth" do
        post "/lakeraven-ehr/transitions_of_care",
          params: { patient_dfn: "1" }
        assert_response :unauthorized
      end

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        post "/lakeraven-ehr/transitions_of_care",
          params: { patient_dfn: "1" },
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "C-CDA serializes filtered patient demographics not raw chart demographics" do
        stub_egress_filter(->(sections) {
          sections.merge(
            patient: sections[:patient].merge(
              name: { family: "FILTERED", given: "DEMOGRAPHIC" }
            )
          )
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :created
        assert_includes response.body, "FILTERED"
        assert_includes response.body, "DEMOGRAPHIC"
        refute_includes response.body, "Anderson"
        refute_includes response.body, "Alice"
      end

      test "C-CDA omits allergy rows withheld by Part 2 egress filter" do
        stub_egress_filter(->(sections) {
          visible = { code: "VISIBLE-ALLERGY", display: "Visible synthetic allergen", code_system: nil }
          with_hidden = sections.merge(
            allergies: sections[:allergies] + [
              { code: "WITHHELD-ALLERGY", display: "Must not appear in C-CDA", code_system: nil }
            ]
          )
          with_hidden.merge(allergies: [ visible ])
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :created
        assert_includes response.body, "VISIBLE-ALLERGY"
        refute_includes response.body, "WITHHELD-ALLERGY"
        refute_includes response.body, "Must not appear in C-CDA"
      end

      test "C-CDA serializes the Part 2 filter return value" do
        marker = { code: "ZZZ-FILTER-MARKER", display: "Filter marker", code_system: nil }
        stub_egress_filter(->(sections) { sections.merge(conditions: [ marker ]) }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :created
        assert_includes response.body, "ZZZ-FILTER-MARKER"
      end

      test "C-CDA is not rendered when the Part 2 filter does not return sections" do
        stub_egress_filter(->(*) { [] }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :service_unavailable
        refute_includes response.body, "ClinicalDocument"
        refute_includes response.body, "Anderson"
      end

      # Round-2 spec (#233): egress dfn must canonicalize to the same patient as
      # params[:patient_dfn], not merely match a positive-integer string regex.
      test "C-CDA is generated when egress filter returns zero-padded dfn for the same patient" do
        stub_egress_filter(->(sections) {
          sections.merge(patient: sections[:patient].merge(dfn: "01"))
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :created
        assert_includes response.body, "ClinicalDocument"
        assert_equal "1", patient_id_extension(response.body)
      end

      test "C-CDA is generated when request patient_dfn is Integer and egress dfn is the same patient" do
        stub_egress_filter(->(sections) {
          sections.merge(patient: sections[:patient].merge(dfn: 1))
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: 1 }, headers: @headers
        end

        assert_response :created
        assert_equal "1", patient_id_extension(response.body)
      end

      test "C-CDA is not rendered when egress filter rewrites patient dfn to REDACTED" do
        assert_refuses_egress_patient_mismatch(rewritten_dfn: "REDACTED")
      end

      # Previously pinned positive_integer_dfn? rejecting non-digit suffixes only.
      # Round-2: any egress dfn whose canonical_dfn differs from the request (here nil).
      test "C-CDA is not rendered when egress filter rewrites patient dfn to non-integer string" do
        assert_refuses_egress_patient_mismatch(rewritten_dfn: "12A")
      end

      test "C-CDA is not rendered when egress filter rewrites patient dfn to another patient" do
        assert_refuses_egress_patient_mismatch(rewritten_dfn: "2")
      end

      test "C-CDA is not rendered when egress filter rewrites patient dfn to zero" do
        assert_refuses_egress_patient_mismatch(rewritten_dfn: "0")
      end

      test "C-CDA is not rendered when egress filter clears patient dfn" do
        assert_refuses_egress_patient_mismatch(rewritten_dfn: "")
      end

      test "C-CDA is not rendered when egress filter nils patient dfn" do
        assert_refuses_egress_patient_mismatch(rewritten_dfn: nil)
      end

      private

      def assert_refuses_egress_patient_mismatch(rewritten_dfn:, request_dfn: "1")
        stub_egress_filter(->(sections) {
          sections.merge(patient: sections[:patient].merge(dfn: rewritten_dfn))
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: request_dfn }, headers: @headers
        end

        assert_response :service_unavailable
        assert_includes response.body, "Part 2 egress filter did not return clinical sections"
        refute_includes response.body, "ClinicalDocument"
      end

      def patient_id_extension(xml)
        doc = Nokogiri::XML(xml)
        doc.at_xpath(
          "//xmlns:patientRole/xmlns:id/@extension",
          "xmlns" => "urn:hl7-org:v3"
        )&.value
      end

      def stub_egress_filter(implementation)
        filter = Part2EgressFilter.singleton_class
        original = filter.instance_method(:call)
        filter.define_method(:call, &implementation)
        yield
      ensure
        filter.define_method(:call, original)
      end
    end
  end
end
