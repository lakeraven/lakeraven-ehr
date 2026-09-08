# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AllergyIntolerancesControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /AllergyIntolerance?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/AllergyIntolerance", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        body["entry"]&.each do |entry|
          assert_equal "AllergyIntolerance", entry.dig("resource", "resourceType")
        end
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/AllergyIntolerance/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }
        assert_response :unauthorized
      end

      # -- Supplemental-resource authorization + read-by-id ---------------------

      def with_supplemental_provider(provider)
        Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider = provider
        yield
      ensure
        Lakeraven::EHR.configuration.supplemental_allergy_intolerances_provider = nil
      end

      def penicillin_for(dfn)
        AllergyIntolerance.new(
          ien: "allergy-#{dfn}-penicillin-g", patient_dfn: dfn.to_s,
          allergen: "Penicillin G", allergen_code: "7980", category: "medication",
          reaction: "Hives", severity: "moderate", criticality: "high"
        )
      end

      # Guards review BLOCKER: pre-fix, supplemental models were appended
      # AFTER authorization with no ownership check, so a supplemental
      # record owned by another (possibly foreign-organization) patient was
      # disclosed inside the requested patient's bundle, carrying its real
      # owner in `patient.reference`.
      test "a supplemental allergy owned by another patient is never disclosed" do
        rogue = ->(_dfn) { [ penicillin_for("1"), penicillin_for("999999") ] }

        with_supplemental_provider(rogue) do
          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
          assert_response :ok
          body = JSON.parse(response.body)
          assert_equal 1, body["total"]
          refs = body["entry"].map { |e| e.dig("resource", "patient", "reference") }
          assert_equal [ "Patient/1" ], refs.uniq,
            "an org-A request must never return a resource referencing a foreign patient"
        end
      end

      # Guards review finding: search emitted ids that show could not
      # resolve. Every id a search returns must be readable.
      test "every id returned by search is readable via show" do
        provider = ->(dfn) { dfn == "1" ? [ penicillin_for("1") ] : [] }

        with_supplemental_provider(provider) do
          RpmsRpc.client.seed_keyed_collection(:allergy_list, "1", [
            { allergen: "SHELLFISH", reaction: "ANAPHYLAXIS", severity: "SEVERE" }
          ])
          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
          ids = JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }
          assert_equal 2, ids.length # one wire-path, one supplemental

          ids.each do |id|
            get "/lakeraven-ehr/AllergyIntolerance/#{id}", headers: @headers
            assert_response :ok
            body = JSON.parse(response.body)
            assert_equal "AllergyIntolerance", body["resourceType"]
            assert_equal id, body["id"]
          end
        ensure
          RpmsRpc.client.seed_keyed_collection(:allergy_list, "1", [])
        end
      end

      # Guards review finding: a resolved foreign resource must be a 403
      # (never served, never a masking 404).
      test "org-bound credential gets 403 for a foreign patient's allergy id" do
        provider = ->(dfn) {
          case dfn
          when "1" then [ penicillin_for("1") ]
          when "999999" then [ penicillin_for("999999") ]
          else []
          end
        }

        with_supplemental_provider(provider) do
          teardown_smart_auth
          setup_smart_auth(scopes: "system/AllergyIntolerance.read")

          get "/lakeraven-ehr/AllergyIntolerance/allergy-1-penicillin-g", headers: @headers
          assert_response :ok

          get "/lakeraven-ehr/AllergyIntolerance/allergy-999999-penicillin-g", headers: @headers
          assert_response :forbidden
        end
      end

      # -- Patient compartment (SMART patient/-scoped tokens) --------------------
      test "patient-bound token reads its own allergy but gets 403 on another patient's" do
        provider = ->(dfn) { %w[1 2].include?(dfn) ? [ penicillin_for(dfn) ] : [] }

        with_supplemental_provider(provider) do
          teardown_smart_auth
          setup_patient_smart_auth(patient: "1")

          get "/lakeraven-ehr/AllergyIntolerance/allergy-1-penicillin-g", headers: @headers
          assert_response :ok
          get "/lakeraven-ehr/AllergyIntolerance/allergy-2-penicillin-g", headers: @headers
          assert_response :forbidden

          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
          assert_response :ok
          get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "2" }, headers: @headers
          assert_response :forbidden
        end
      end
    end
  end
end
