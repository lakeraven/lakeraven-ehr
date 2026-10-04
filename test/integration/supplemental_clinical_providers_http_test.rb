# frozen_string_literal: true

require "test_helper"

# HTTP contract for supplemental clinical providers (ObservationsController and
# AllergyIntolerancesController entry points).
module Lakeraven
  module EHR
    class SupplementalClinicalProvidersHttpTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include SupplementalProviderConfigHelper

      REQUESTED_DFN = "1"
      FOREIGN_DFN = "2"

      setup do
        setup_smart_auth(scopes: "system/*.read")
      end

      teardown do
        teardown_smart_auth
      end

      test "supplemental laboratory observation appears in Observation search for the requested patient" do
        # Catches wiring supplemental rows only into an internal helper, not the FHIR index.
        lab = laboratory_observation(
          ien: "supp-lab-hba1c",
          patient_dfn: REQUESTED_DFN,
          code: "4548-4",
          display: "Hemoglobin A1c"
        )

        with_supplemental_providers(observations: ->(_dfn) { [ lab ] }) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :ok
          body = JSON.parse(response.body)
          entries = body.fetch("entry")
          assert entries.any?, "expected a non-empty Observation bundle"
          ids = entries.map { |e| e.dig("resource", "id") }
          assert_includes ids, "supp-lab-hba1c"
        end
      end

      test "supplemental observation serializes through the same Observation serializer as wire vitals" do
        # Catches rendering supplemental rows as raw hashes while vitals use Observation#to_fhir.
        lab = laboratory_observation(
          ien: "supp-lab-serialize",
          patient_dfn: REQUESTED_DFN,
          code: "4548-4",
          display: "Hemoglobin A1c"
        )

        with_supplemental_providers(observations: ->(_dfn) { [ lab ] }) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :ok
          entries = JSON.parse(response.body).fetch("entry")
          assert entries.any?, "expected observations in bundle"

          vital_entry = entries.find { |e| e.dig("resource", "category", 0, "coding", 0, "code") == "vital-signs" }
          lab_entry = entries.find { |e| e.dig("resource", "id") == "supp-lab-serialize" }
          assert vital_entry, "expected at least one wire-sourced vital-signs observation"
          assert lab_entry, "expected supplemental laboratory observation in bundle"

          vital = vital_entry["resource"]
          lab_res = lab_entry["resource"]
          assert_equal "Observation", lab_res["resourceType"]
          assert_equal "Patient/#{REQUESTED_DFN}", lab_res.dig("subject", "reference")
          assert_equal "Observation", vital["resourceType"]
          assert_equal "Patient/#{REQUESTED_DFN}", vital.dig("subject", "reference")
          assert lab_res["valueQuantity"].is_a?(Hash), "supplemental lab must use valueQuantity object"
          assert lab_res["valueQuantity"]["value"].is_a?(Numeric),
                 "supplemental lab valueQuantity.value must be a JSON number like wire vitals"
          assert_equal "laboratory", lab_res.dig("category", 0, "coding", 0, "code")
        end
      end

      test "category filter applies to supplemental observations" do
        # Catches appending supplemental rows after filters, bypassing search params.
        lab = laboratory_observation(
          ien: "supp-lab-filter",
          patient_dfn: REQUESTED_DFN,
          code: "4548-4",
          display: "Hemoglobin A1c"
        )

        with_supplemental_providers(observations: ->(_dfn) { [ lab ] }) do
          get "/lakeraven-ehr/Observation",
            params: { patient: REQUESTED_DFN, category: "laboratory" },
            headers: @headers
          assert_response :ok
          entries = JSON.parse(response.body).fetch("entry")
          assert entries.any?, "expected laboratory supplemental observation"
          entries.each do |entry|
            code = entry.dig("resource", "category", 0, "coding", 0, "code")
            assert_equal "laboratory", code
          end
        end
      end

      test "foreign supplemental observation never appears in another patient Observation search" do
        # Catches compartment bypass via the supplemental seam at the HTTP boundary.
        foreign = laboratory_observation(
          ien: "supp-lab-leak",
          patient_dfn: FOREIGN_DFN,
          code: "4548-4",
          display: "Leaked lab"
        )

        with_supplemental_providers(observations: ->(_dfn) { [ foreign ] }) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :ok
          entries = JSON.parse(response.body).fetch("entry")
          assert entries.any?, "expected wire observations for patient 1"
          ids = entries.map { |e| e.dig("resource", "id") }
          refute_includes ids, "supp-lab-leak"
        end
      end

      test "configured observations provider that raises fails the Observation index visibly" do
        # Catches rescue-to-empty supplemental that looks like an unconfigured deployment.
        with_supplemental_providers(
          observations: ->(_dfn) { raise SupplementalProviderError, "adapter down" }
        ) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :internal_server_error
          body = JSON.parse(response.body)
          assert_equal "OperationOutcome", body["resourceType"]
        end
      end

      test "without supplemental providers Observation index matches wire-only results" do
        # Regression guard: unused seam must not change FHIR output.
        with_supplemental_providers(observations: nil, allergy_intolerances: nil) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :ok
          baseline_ids = bundle_resource_ids
          assert baseline_ids.any?, "expected wire observations"

          with_supplemental_providers(observations: ->(_dfn) { [] }) do
            get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
            assert_response :ok
            assert_equal baseline_ids.sort, bundle_resource_ids.sort
          end
        end
      end

      test "supplemental coded allergy appears in AllergyIntolerance search with FHIR fields" do
        # Catches serving coded/criticality allergies only through a side channel.
        allergy = coded_allergy(
          ien: "supp-allergy-coded",
          patient_dfn: REQUESTED_DFN,
          allergen: "Supplemental Coded Drug",
          allergen_code: "1191",
          criticality: "high"
        )

        with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ allergy ] }) do
          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :ok
          entries = JSON.parse(response.body).fetch("entry")
          assert entries.any?, "expected allergy bundle entries"
          resource = entries.map { |e| e["resource"] }.find { |r| r["id"] == "supp-allergy-coded" }
          assert resource, "expected supplemental allergy in bundle"
          assert_equal "AllergyIntolerance", resource["resourceType"]
          assert_equal "Patient/#{REQUESTED_DFN}", resource.dig("patient", "reference")
          assert_equal "high", resource["criticality"]
          coding = resource.dig("code", "coding")
          assert coding.is_a?(Array) && coding.any?, "coded supplemental allergy must expose code.coding"
          assert_equal "1191", coding.first["code"]
        end
      end

      test "configured allergy provider that raises fails the AllergyIntolerance index visibly" do
        # Catches silent omission of coded allergies when the adapter is broken.
        with_supplemental_providers(
          allergy_intolerances: ->(_dfn) { raise SupplementalProviderError, "allergy adapter down" }
        ) do
          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :internal_server_error
          body = JSON.parse(response.body)
          assert_equal "OperationOutcome", body["resourceType"]
        end
      end

      test "foreign supplemental allergy never appears in another patient AllergyIntolerance search" do
        # Catches allergy compartment bypass through supplemental providers.
        foreign = coded_allergy(
          ien: "supp-allergy-leak",
          patient_dfn: FOREIGN_DFN,
          allergen: "Leaked Allergen"
        )

        with_supplemental_providers(allergy_intolerances: ->(_dfn) { [ foreign ] }) do
          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :ok
          entries = JSON.parse(response.body).fetch("entry")
          ids = entries.map { |e| e.dig("resource", "id") }
          refute_includes ids, "supp-allergy-leak"
        end
      end

      test "supplemental clinical data requires the same SMART scopes as wire-sourced data" do
        # Catches a second authorization path that serves provider rows without Observation.read.
        teardown_smart_auth
        setup_smart_auth(scopes: "system/Patient.read")

        lab = laboratory_observation(
          ien: "supp-lab-authz",
          patient_dfn: REQUESTED_DFN,
          code: "4548-4",
          display: "Hemoglobin A1c"
        )

        with_supplemental_providers(observations: ->(_dfn) { [ lab ] }) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :forbidden
          refute_includes response.body, "supp-lab-authz"
        end
      end

      test "patient-bound token cannot use supplemental data to read another patient observations" do
        # Catches supplemental merge happening before patient compartment enforcement.
        teardown_smart_auth
        setup_patient_bound_auth(scopes: "patient/Observation.read", resource_owner_id: 999)

        lab = laboratory_observation(
          ien: "supp-lab-compartment",
          patient_dfn: REQUESTED_DFN,
          code: "4548-4",
          display: "Hemoglobin A1c"
        )

        with_supplemental_providers(observations: ->(_dfn) { [ lab ] }) do
          get "/lakeraven-ehr/Observation", params: { patient: REQUESTED_DFN }, headers: @headers
          assert_response :forbidden
          refute_includes response.body, "supp-lab-compartment"
        end
      end

      private

      def setup_patient_bound_auth(scopes:, resource_owner_id:)
        @oauth_app = Doorkeeper::Application.create!(
          name: "patient-bound-#{SecureRandom.hex(4)}",
          redirect_uri: "https://example.test/callback",
          scopes: scopes,
          confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: @oauth_app,
          scopes: scopes,
          expires_in: 3600,
          resource_owner_id: resource_owner_id
        )
        @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      def bundle_resource_ids
        JSON.parse(response.body).fetch("entry").map { |e| e.dig("resource", "id") }
      end

      def laboratory_observation(ien:, patient_dfn:, code:, display:)
        Observation.new(
          ien: ien,
          patient_dfn: patient_dfn,
          code: code,
          code_system: "loinc",
          display: display,
          value_quantity: "6.1",
          unit: "%",
          category: "laboratory",
          status: "final",
          effective_datetime: Time.utc(2025, 6, 1, 12, 0, 0)
        )
      end

      def coded_allergy(ien:, patient_dfn:, allergen:, allergen_code: nil, criticality: nil)
        AllergyIntolerance.new(
          ien: ien,
          patient_dfn: patient_dfn,
          allergen: allergen,
          allergen_code: allergen_code,
          criticality: criticality,
          category: "medication",
          clinical_status: "active",
          reaction: "Hives",
          severity: "moderate"
        )
      end
    end
  end
end
