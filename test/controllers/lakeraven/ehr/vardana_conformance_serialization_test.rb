# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Vardana source-system profile (sections 3-5, conformance checklist
    # section 7): the four core resources serve valid US Core FHIR through
    # an org-bound backend credential — correct codings, units, clinical
    # dates, BP components, pagination, stable ids, and a distinguishable
    # corrected value.
    class VardanaConformanceSerializationTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      VITALS_TAKEN = DateTime.new(2026, 2, 1, 9, 30, 0)

      class FakeGateway
        def initialize(rows) = @rows = rows
        def for_patient(_dfn) = @rows
      end

      setup do
        setup_smart_auth # org-bound system credential (rpms-organization-7819)

        Condition.gateway = FakeGateway.new([
          { ien: "1", status: "A", description: "Type 2 diabetes mellitus",
            icd_code: "E11.9", onset_date: Date.new(2020, 3, 1), recorded_date: Date.new(2020, 3, 2) },
          { ien: "2", status: "I", description: "Ankle sprain", icd_code: "S93.401" }
        ])
        MedicationRequest.gateway = FakeGateway.new([
          { ien: "11", drug_name: "Lisinopril 10mg", sig: "1 tab PO daily", status: "ACTIVE", refills: 3 },
          { ien: "12", drug_name: "Amoxicillin 500mg", sig: "1 cap PO TID", status: "EXPIRED", refills: 0 }
        ])
        Observation.gateway = FakeGateway.new([
          { type: "BP", value: "128/82", units: "mm[Hg]", recorded_date: VITALS_TAKEN },
          { type: "WT", value: "180", units: "[lb_av]", recorded_date: VITALS_TAKEN },
          { type: "P", value: "74", units: "/min", recorded_date: VITALS_TAKEN - 30.days }
        ])
        Lakeraven::EHR.configuration.supplemental_observations_provider = ->(dfn) {
          [ Observation.new(
            ien: "lab-#{dfn}-hba1c-20260115", patient_dfn: dfn, code: "4548-4",
            code_system: "loinc", display: "Hemoglobin A1c", value_quantity: "7.2",
            unit: "%", category: "laboratory", status: "corrected",
            effective_datetime: DateTime.new(2026, 1, 15, 8, 0, 0)
          ) ]
        }
      end

      teardown do
        teardown_smart_auth
        Condition.gateway = nil
        MedicationRequest.gateway = nil
        Observation.gateway = nil
        Lakeraven::EHR.configuration.supplemental_observations_provider = nil
        ProvenanceStore.reset_instance!
        PatientSupplement.delete_all
      end

      # -- Patient: phone + managingOrganization ----------------------------

      test "Patient read carries the supplemented phone in telecom" do
        PatientSupplement.create!(patient_dfn: 1, phone: "555-0142")

        get "/lakeraven-ehr/Patient/1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        phone = Array(body["telecom"]).find { |t| t["system"] == "phone" }
        assert_equal "555-0142", phone["value"]
      end

      test "Patient read carries managingOrganization from the site" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Organization/7819", body.dig("managingOrganization", "reference")
      end

      # -- Condition: US Core shape + clinical-status search ----------------

      test "Conditions serialize as US Core FHIR with statuses and codings" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 2, body["total"]

        condition = body["entry"].map { |e| e["resource"] }.find { |r| r["id"] == "1" }
        assert_equal "Condition", condition["resourceType"]
        assert_equal "Patient/1", condition.dig("subject", "reference")
        assert_equal "active", condition.dig("clinicalStatus", "coding", 0, "code")
        assert_equal "confirmed", condition.dig("verificationStatus", "coding", 0, "code")
        coding = condition.dig("code", "coding", 0)
        assert_equal "E11.9", coding["code"]
        assert_equal "http://hl7.org/fhir/sid/icd-10-cm", coding["system"]
        assert_equal "Type 2 diabetes mellitus", condition.dig("code", "text")
        assert_equal "2020-03-01", condition["onsetDateTime"][0, 10]
        assert_equal "2020-03-02", condition["recordedDate"]
      end

      test "Condition search filters by clinical-status=active" do
        get "/lakeraven-ehr/Condition", params: { patient: "1", "clinical-status": "active" },
          headers: @headers
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]
        assert_equal "1", body["entry"].first.dig("resource", "id")
      end

      # -- MedicationRequest: US Core shape + status search -----------------

      test "MedicationRequests serialize as FHIR with status, intent, and dosage" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 2, body["total"]

        med = body["entry"].map { |e| e["resource"] }.find { |r| r["id"] == "11" }
        assert_equal "MedicationRequest", med["resourceType"]
        assert_equal "active", med["status"]
        assert_equal "order", med["intent"]
        assert_equal "Patient/1", med.dig("subject", "reference")
        assert_equal "Lisinopril 10mg", med.dig("medicationCodeableConcept", "text")
        assert_equal "1 tab PO daily", med.dig("dosageInstruction", 0, "text")
      end

      test "MedicationRequest search filters by status=active" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1", status: "active" },
          headers: @headers
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]
        assert_equal "11", body["entry"].first.dig("resource", "id")
      end

      # -- Observation: LOINC + units + BP components + corrected status ----

      test "blood pressure round-trips with both components and units" do
        get "/lakeraven-ehr/Observation", params: { patient: "1", code: "85354-9" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]

        bp = body["entry"].first["resource"]
        assert_equal "final", bp["status"]
        assert_equal VITALS_TAKEN.iso8601, bp["effectiveDateTime"]
        components = bp["component"].to_h { |c| [ c.dig("code", "coding", 0, "code"), c["valueQuantity"] ] }
        assert_equal 128.0, components["8480-6"]["value"]
        assert_equal 82.0, components["8462-4"]["value"]
        assert_equal [ "mm[Hg]" ], components.values.map { |q| q["unit"] }.uniq
        assert_equal [ "http://unitsofmeasure.org" ], components.values.map { |q| q["system"] }.uniq
      end

      test "supplemental laboratory observation serves LOINC, units, clinical date, and corrected status" do
        get "/lakeraven-ehr/Observation", params: { patient: "1", code: "4548-4" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]

        lab = body["entry"].first["resource"]
        assert_equal "corrected", lab["status"]
        assert_equal "4548-4", lab.dig("code", "coding", 0, "code")
        assert_equal "http://loinc.org", lab.dig("code", "coding", 0, "system")
        assert_equal 7.2, lab.dig("valueQuantity", "value")
        assert_equal "%", lab.dig("valueQuantity", "unit")
        assert_equal "2026-01-15", lab["effectiveDateTime"][0, 10]
        assert_equal "laboratory", lab.dig("category", 0, "coding", 0, "code")
      end

      test "Observation date=ge filter and _sort=-date order the result" do
        get "/lakeraven-ehr/Observation",
          params: { patient: "1", date: "ge2026-01-10", _sort: "-date" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal 3, body["total"] # BP + WT + HbA1c; the Jan 2 pulse is excluded

        dates = body["entry"].map { |e| e.dig("resource", "effectiveDateTime") }
        assert_equal dates.sort.reverse, dates
      end

      test "Observation ids are stable across reads" do
        ids = 2.times.map do
          get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
          JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }.sort
        end
        assert_equal ids.first, ids.last
        assert ids.first.all?(&:present?)
      end

      # -- Pagination: _count + Bundle.link next ----------------------------

      test "pagination returns the complete set across more than one page" do
        get "/lakeraven-ehr/Observation", params: { patient: "1", _count: "2" }, headers: @headers
        first = JSON.parse(response.body)
        assert_equal 4, first["total"]
        assert_equal 2, first["entry"].length

        next_link = first["link"].find { |l| l["relation"] == "next" }
        assert next_link, "expected a Bundle.link with relation 'next'"

        get URI.parse(next_link["url"]).request_uri, headers: @headers
        second = JSON.parse(response.body)
        assert_equal 2, second["entry"].length
        assert_nil second["link"].find { |l| l["relation"] == "next" }

        all_ids = (first["entry"] + second["entry"]).map { |e| e.dig("resource", "id") }
        assert_equal 4, all_ids.uniq.length
      end

      # -- Provenance via _revinclude ---------------------------------------

      test "_revinclude=Provenance:target distinguishes office-measured from patient-reported" do
        bp_id = "vital-1-bp-#{VITALS_TAKEN.strftime('%Y%m%d%H%M')}"
        ProvenanceStore.instance.add(Provenance.new(
          fhir_id: "prov-#{bp_id}", target_type: "Observation", target_id: bp_id,
          recorded: VITALS_TAKEN, agent_who_type: "Practitioner", agent_who_id: "101",
          agent_type: "performer"
        ))

        get "/lakeraven-ehr/Observation",
          params: { patient: "1", code: "85354-9", _revinclude: "Provenance:target" },
          headers: @headers
        body = JSON.parse(response.body)

        includes = body["entry"].select { |e| e.dig("search", "mode") == "include" }
        assert_equal 1, includes.length
        prov = includes.first["resource"]
        assert_equal "Provenance", prov["resourceType"]
        assert_equal "Observation/#{bp_id}", prov.dig("target", 0, "reference")
        assert_equal "Practitioner/101", prov.dig("agent", 0, "who", "reference")
        assert_equal "performer", prov.dig("agent", 0, "type", 0, "coding", 0, "code")
        # Provenance rides along and never counts toward the match total
        assert_equal 1, body["total"]
      end
    end
  end
end
