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

      # 42 CFR § 2.32 (#909): the C-CDA path cannot carry the redisclosure
      # notice, so a Part 2-labelled row must not leave through it.
      test "C-CDA is refused when a condition row carries a Part 2 label" do
        displays = []
        with_real_egress_filter(->(sections) {
          labelled = { code: "F10.20", display: "ZZZ-PART2-CONDITION-DISPLAY", code_system: nil,
                       security: [ { code: "42CFRPart2" } ] }
          displays.concat(sections[:conditions].filter_map { |row| row[:display].presence })
          sections.merge(conditions: sections[:conditions] + [ labelled ])
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :service_unavailable
        refute_includes response.body, "ClinicalDocument"
        refute_includes response.body, "ZZZ-PART2-CONDITION-DISPLAY"
        refute_includes response.body, "F10.20"
        displays.each { |display| refute_includes response.body, display.to_s }
      end

      test "C-CDA with no Part 2 label still renders through the real egress filter" do
        with_real_egress_filter(->(sections) {
          plain = { code: "ZZZ-UNLABELLED", display: "ZZZ-UNLABELLED-CONDITION-DISPLAY", code_system: nil }
          sections.merge(conditions: sections[:conditions] + [ plain ])
        }) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :created
        assert_includes response.body, "ClinicalDocument"
        assert_includes response.body, "ZZZ-UNLABELLED-CONDITION-DISPLAY"
      end

      # The label has to come from the model, not from a test wrapper: the
      # rows the controller builds keep the security labels of what
      # Condition.for_patient returned, and the REAL filter refuses them.
      test "C-CDA is refused when a condition model's to_fhir carries a Part 2 label" do
        labelled = SyntheticCondition.new(
          "F10.20", "ZZZ-MODEL-PART2-DISPLAY", "http://hl7.org/fhir/sid/icd-10-cm",
          [ { "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code" => "42CFRPart2" } ]
        )
        plain = SyntheticCondition.new("ZZZ-PLAIN", "ZZZ-MODEL-PLAIN-DISPLAY", nil, nil)

        stub_condition_rows([ plain, labelled ]) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :service_unavailable
        refute_includes response.body, "ClinicalDocument"
        refute_includes response.body, "ZZZ-MODEL-PART2-DISPLAY"
        refute_includes response.body, "ZZZ-MODEL-PLAIN-DISPLAY"
        refute_includes response.body, "F10.20"
      end

      test "C-CDA is refused when a condition model's to_fhir carries a SUD sensitivity label" do
        labelled = SyntheticCondition.new("F11.20", "ZZZ-MODEL-SUD-DISPLAY", nil, [ { "code" => "SUD" } ])

        stub_condition_rows([ labelled ]) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :service_unavailable
        refute_includes response.body, "ClinicalDocument"
        refute_includes response.body, "ZZZ-MODEL-SUD-DISPLAY"
      end

      test "C-CDA is refused when a condition Hash row carries a security label" do
        row = { code: "F10.20", display: "ZZZ-HASH-PART2-DISPLAY", code_system: nil, security: [ { code: "SUD" } ] }

        stub_condition_rows([ row ]) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :service_unavailable
        refute_includes response.body, "ClinicalDocument"
        refute_includes response.body, "ZZZ-HASH-PART2-DISPLAY"
      end

      test "C-CDA renders a condition model whose to_fhir has no security label" do
        plain = SyntheticCondition.new("ZZZ-PLAIN", "ZZZ-MODEL-PLAIN-DISPLAY", nil, nil)
        hash_row = { code: "ZZZ-HASH", display: "ZZZ-HASH-PLAIN-DISPLAY", code_system: nil }

        stub_condition_rows([ plain, hash_row ]) do
          post "/lakeraven-ehr/transitions_of_care",
            params: { patient_dfn: "1" }, headers: @headers
        end

        assert_response :created
        assert_includes response.body, "ClinicalDocument"
        assert_includes response.body, "ZZZ-MODEL-PLAIN-DISPLAY"
        assert_includes response.body, "ZZZ-HASH-PLAIN-DISPLAY"
      end

      private

      # A model-like condition: what the controller reads (code, display,
      # code_system) plus to_fhir, whose meta.security holds the labels the
      # record was stored with. Synthetic values only.
      SyntheticCondition = Struct.new(:code, :display, :code_system, :security) do
        def to_fhir
          resource = { "resourceType" => "Condition", "id" => "syn-#{code}", "code" => { "text" => display } }
          security ? resource.merge("meta" => { "security" => security }) : resource
        end
      end

      # Condition.for_patient returns `rows` for the block. The real
      # Part2EgressFilter runs: it is not stubbed here.
      def stub_condition_rows(rows)
        model = Condition.singleton_class
        original = model.instance_method(:for_patient)
        model.define_method(:for_patient) { |*| rows }
        yield
      ensure
        model.define_method(:for_patient, original)
      end

      # Runs the REAL Part2EgressFilter.call on the sections after `prepare`
      # has changed them, so the test sees what the real filter decides.
      def with_real_egress_filter(prepare, &block)
        real = Part2EgressFilter.singleton_class.instance_method(:call).bind(Part2EgressFilter)
        stub_egress_filter(->(sections) { real.call(prepare.call(sections)) }, &block)
      end

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
