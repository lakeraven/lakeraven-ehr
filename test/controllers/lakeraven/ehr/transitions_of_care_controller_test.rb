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

      # --- round 2: the C-CDA sees every label on the item, and the patient ---
      #
      # The C-CDA cannot carry the notice. So whatever the FHIR path would
      # notice or refuse on an item must refuse the document: a label in a
      # Hash row's meta, in a model's meta.tag, on a resource in a model's
      # contained, on the Patient, and on an allergy or a medication as well
      # as a condition. The REAL filter runs in each of these tests.

      test "C-CDA is refused when a condition Hash row carries the label in meta.security" do
        row = { code: "F10.20", display: "ZZZ-HASH-META-DISPLAY", meta: { security: [ { code: "SUD" } ] } }
        plain = { code: "ZZZ-PLAIN", display: "ZZZ-HASH-META-PLAIN-DISPLAY", code_system: nil }

        stub_for_patient(Condition, [ plain, row ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-HASH-META-DISPLAY", "ZZZ-HASH-META-PLAIN-DISPLAY", "F10.20")
      end

      test "C-CDA is refused when a condition Hash row carries the label in string-keyed meta.security" do
        row = { code: "F10.20", display: "ZZZ-HASH-STRMETA-DISPLAY", "meta" => { "security" => [ { "code" => "42CFRPart2" } ] } }

        stub_for_patient(Condition, [ row ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-HASH-STRMETA-DISPLAY", "F10.20")
      end

      test "C-CDA is refused when a condition model's to_fhir carries the label only in meta.tag" do
        labelled = SyntheticRecord.new("F10.20", "ZZZ-MODEL-TAG-DISPLAY",
          "resourceType" => "Condition", "id" => "syn-tag", "meta" => { "tag" => [ { "code" => "42CFRPart2" } ] })

        stub_for_patient(Condition, [ labelled ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-MODEL-TAG-DISPLAY", "F10.20")
      end

      test "C-CDA is refused when a condition model's to_fhir holds a labelled resource only in contained" do
        labelled = SyntheticRecord.new("F11.20", "ZZZ-MODEL-CONTAINED-DISPLAY",
          "resourceType" => "Condition", "id" => "syn-outer",
          "contained" => [
            { "resourceType" => "Observation", "id" => "syn-inner", "meta" => { "security" => [ { "code" => "SUD" } ] } }
          ])

        stub_for_patient(Condition, [ labelled ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-MODEL-CONTAINED-DISPLAY", "F11.20")
      end

      test "C-CDA is refused when a symbol-keyed model to_fhir holds a labelled resource in contained" do
        labelled = SyntheticRecord.new("F11.20", "ZZZ-MODEL-SYMCONTAINED-DISPLAY",
          resourceType: "Condition", id: "syn-outer",
          contained: [ { resourceType: "Observation", id: "syn-inner", meta: { security: [ { code: "ETH" } ] } } ])

        stub_for_patient(Condition, [ labelled ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-MODEL-SYMCONTAINED-DISPLAY", "F11.20")
      end

      test "C-CDA is refused when the Patient is Part 2-labelled and the rows are not" do
        patient = Patient.find_by_dfn("1")
        assert patient, "the synthetic patient 1 must exist"
        base = patient.to_fhir
        symbols = base.is_a?(Hash) && base.key?(:resourceType)
        label = { "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code" => "42CFRPart2" }
        fhir = symbols ? base.merge(meta: { security: [ label.symbolize_keys ] }) : base.merge("meta" => { "security" => [ label ] })
        patient.define_singleton_method(:to_fhir) { fhir }
        plain = { code: "ZZZ-PLAIN", display: "ZZZ-LABELLED-PATIENT-ROW-DISPLAY", code_system: nil }

        stub_class_method(Patient, :find_by_dfn, ->(*) { patient }) do
          stub_for_patient(Condition, [ plain ]) do
            post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
          end
        end

        assert_ccda_refused("ZZZ-LABELLED-PATIENT-ROW-DISPLAY", "Anderson", "Alice", "recordTarget")
      end

      test "C-CDA is refused when the Patient's to_fhir carries a SUD label in meta.tag" do
        patient = Patient.find_by_dfn("1")
        fhir = { "resourceType" => "Patient", "id" => "1", "meta" => { "tag" => [ { "code" => "SUD" } ] } }
        patient.define_singleton_method(:to_fhir) { fhir }

        stub_class_method(Patient, :find_by_dfn, ->(*) { patient }) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("Anderson", "Alice", "recordTarget")
      end

      test "C-CDA is refused when an AllergyIntolerance model is labelled in meta.security" do
        labelled = SyntheticRecord.new("ZZZ-ALLERGEN", "ZZZ-ALLERGY-PART2-DISPLAY",
          resourceType: "AllergyIntolerance", id: "syn-allergy",
          meta: { security: [ { system: "http://terminology.hl7.org/CodeSystem/v3-ActCode", code: "42CFRPart2" } ] })
        plain = SyntheticRecord.new("ZZZ-PLAIN-ALLERGEN", "ZZZ-ALLERGY-PLAIN-DISPLAY",
          resourceType: "AllergyIntolerance", id: "syn-plain")

        stub_for_patient(AllergyIntolerance, [ plain, labelled ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-ALLERGY-PART2-DISPLAY", "ZZZ-ALLERGY-PLAIN-DISPLAY", "ZZZ-ALLERGEN")
      end

      test "C-CDA is refused when a MedicationRequest model is labelled in meta.security" do
        labelled = SyntheticRecord.new("ZZZ-MED", "ZZZ-MEDICATION-PART2-DISPLAY",
          resourceType: "MedicationRequest", id: "syn-med", meta: { security: [ { code: "SUD" } ] })

        stub_for_patient(MedicationRequest, [ labelled ]) do
          post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
        end

        assert_ccda_refused("ZZZ-MEDICATION-PART2-DISPLAY", "ZZZ-MED")
      end

      test "C-CDA is refused when an allergy or medication Hash row carries the label in meta.security" do
        { AllergyIntolerance => { allergen_code: "ZZZ-A", allergen: "ZZZ-ALLERGY-HASH-DISPLAY" },
          MedicationRequest => { medication_code: "ZZZ-M", medication_display: "ZZZ-MEDICATION-HASH-DISPLAY" } }.each do |model, row|
          stub_for_patient(model, [ row.merge(meta: { security: [ { code: "ETH" } ] }) ]) do
            post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
          end

          assert_ccda_refused("ZZZ-ALLERGY-HASH-DISPLAY", "ZZZ-MEDICATION-HASH-DISPLAY")
        end
      end

      # The other half: nothing unlabelled is refused, and nothing the filter
      # was shown (the items' FHIR forms) reaches the document. The XML is
      # the same as the one built from rows that carry only code and display.
      test "C-CDA from unlabelled models, Hash rows and Patient is unchanged and leaks no FHIR form" do
        unrelated = { "system" => "http://terminology.hl7.org/CodeSystem/v3-Confidentiality", "code" => "N" }
        fhir_only = ->(type, id) {
          { "resourceType" => type, "id" => "ZZZ-FHIR-ONLY-#{id}", "meta" => { "security" => [ unrelated ], "versionId" => "ZZZ-FHIR-ONLY-VERSION" },
            "note" => [ { "text" => "ZZZ-FHIR-ONLY-NOTE" } ],
            "contained" => [ { "resourceType" => "Observation", "id" => "ZZZ-FHIR-ONLY-CONTAINED" } ] }
        }
        rows = {
          AllergyIntolerance => [
            SyntheticRecord.new("ZZZ-A1", "ZZZ-ALLERGY-ONE", fhir_only.("AllergyIntolerance", "A1")),
            { allergen_code: "ZZZ-A2", allergen: "ZZZ-ALLERGY-TWO", meta: { security: [ { code: "N" } ], tag: [ { code: "ZZZ-HASH-ONLY-TAG" } ] } }
          ],
          Condition => [
            SyntheticRecord.new("ZZZ-C1", "ZZZ-CONDITION-ONE", fhir_only.("Condition", "C1"), "http://hl7.org/fhir/sid/icd-10-cm"),
            { code: "ZZZ-C2", display: "ZZZ-CONDITION-TWO", code_system: nil, meta: { security: [ { code: "N" } ] }, zzz_hash_only_key: "ZZZ-HASH-ONLY-VALUE" }
          ],
          MedicationRequest => [
            SyntheticRecord.new("ZZZ-M1", "ZZZ-MEDICATION-ONE", fhir_only.("MedicationRequest", "M1")),
            { medication_code: "ZZZ-M2", medication_display: "ZZZ-MEDICATION-TWO" }
          ]
        }
        bare = {
          AllergyIntolerance => [ { allergen_code: "ZZZ-A1", allergen: "ZZZ-ALLERGY-ONE" }, { allergen_code: "ZZZ-A2", allergen: "ZZZ-ALLERGY-TWO" } ],
          Condition => [ { code: "ZZZ-C1", display: "ZZZ-CONDITION-ONE", code_system: "http://hl7.org/fhir/sid/icd-10-cm" },
                         { code: "ZZZ-C2", display: "ZZZ-CONDITION-TWO", code_system: nil } ],
          MedicationRequest => [ { medication_code: "ZZZ-M1", medication_display: "ZZZ-MEDICATION-ONE" },
                                 { medication_code: "ZZZ-M2", medication_display: "ZZZ-MEDICATION-TWO" } ]
        }
        patient = Patient.find_by_dfn("1")
        patient_fhir = patient.to_fhir.deep_stringify_keys.merge(
          "meta" => { "security" => [ unrelated ], "versionId" => "ZZZ-FHIR-ONLY-PATIENT-VERSION" }
        )
        patient.define_singleton_method(:to_fhir) { patient_fhir }

        with_fhir_forms = ccda_for(rows, patient: patient)
        assert_response :created
        assert_equal "application/xml", response.media_type
        expected = ccda_for(bare)
        assert_response :created

        %w[ZZZ-ALLERGY-ONE ZZZ-ALLERGY-TWO ZZZ-CONDITION-ONE ZZZ-CONDITION-TWO ZZZ-MEDICATION-ONE ZZZ-MEDICATION-TWO
           ZZZ-A1 ZZZ-C2 ZZZ-M1 ClinicalDocument Anderson].each do |shown|
          assert_includes with_fhir_forms, shown
        end
        %w[ZZZ-FHIR-ONLY ZZZ-HASH-ONLY resourceType versionId zzz_hash_only_key v3-Confidentiality].each do |leak|
          refute_includes with_fhir_forms, leak, "the item's FHIR form must not reach the C-CDA (#{leak})"
        end
        assert_equal stable_ccda(expected), stable_ccda(with_fhir_forms),
          "the C-CDA must be the one built from code and display alone"
      end

      private

      # A model-like record for any of the three C-CDA lists: the readers
      # the controller uses for a condition, an allergy and a medication,
      # plus to_fhir, which returns the FHIR form given. Synthetic only.
      SyntheticRecord = Struct.new(:code, :display, :fhir, :code_system) do
        alias_method :allergen_code, :code
        alias_method :allergen, :display
        alias_method :medication_code, :code
        alias_method :medication_display, :display

        def to_fhir
          fhir
        end
      end

      # The 503 of a refused C-CDA: no document, and none of `absent` in it.
      def assert_ccda_refused(*absent)
        assert_response :service_unavailable
        refute_includes response.body, "ClinicalDocument"
        absent.each { |text| refute_includes response.body, text }
      end

      # `model.for_patient` returns `rows` for the block. The real
      # Part2EgressFilter runs: it is not stubbed here.
      def stub_for_patient(model, rows, &block)
        stub_class_method(model, :for_patient, ->(*) { rows }, &block)
      end

      def stub_class_method(model, name, implementation)
        singleton = model.singleton_class
        own = singleton.instance_methods(false).include?(name) || singleton.private_instance_methods(false).include?(name)
        original = singleton.instance_method(name)
        singleton.define_method(name, &implementation)
        yield
      ensure
        own ? singleton.define_method(name, original) : singleton.send(:remove_method, name)
      end

      # POSTs with each model's for_patient stubbed to `rows_by_model`, and
      # returns the body.
      def ccda_for(rows_by_model, patient: nil)
        request = -> { post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers }
        stubbed = rows_by_model.reduce(request) do |inner, (model, rows)|
          -> { stub_for_patient(model, rows, &inner) }
        end
        patient ? stub_class_method(Patient, :find_by_dfn, ->(*) { patient }, &stubbed) : stubbed.call
        response.body
      end

      # The document without what differs between two renders of the same
      # chart: the document id and the times it was generated.
      def stable_ccda(xml)
        doc = Nokogiri::XML(xml)
        doc.remove_namespaces!
        doc.xpath("/ClinicalDocument/id | /ClinicalDocument/effectiveTime | //author/time | //@root[string-length(.) = 36]").each(&:remove)
        doc.to_xml
      end

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
      def stub_condition_rows(rows, &block)
        stub_for_patient(Condition, rows, &block)
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
