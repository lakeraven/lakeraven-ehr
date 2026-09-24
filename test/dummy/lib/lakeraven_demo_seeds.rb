# frozen_string_literal: true

# Synthetic demo seed data for the read-only patient chart (issue #452).
#
# Single source of truth shared by:
#   * test/dummy/config/initializers/zz_spike_mock_rpc.rb  (dev, SPIKE-gated)
#   * the chart request test
#
# Seeds RpmsRpc's in-memory MockClient so the chart endpoint serves real
# FHIR reads through the engine's own gateways/models with NO live RPMS.
#
# SYNTHETIC DATA ONLY — invented patient "Anderson, Alice" (DFN 1) and an
# invented facility. No PHI, no real person/tribe/org names.

require "rpms_rpc/api/measurement"
require "rpms_rpc/api/ddr_fileman"

module LakeravenDemoSeeds
  module_function

  # Seed a MockClient (`m`) with demographics + clinical data for DFN 1.
  #
  # Vital `type` codes use RPMS-native abbreviations (BP/P/T/WT on the
  # ORQQVI index; canonical BP/PU/TMP/WT on the DDR read) so the engine's
  # Observation.from_measurement_hashes VITAL_TYPE_MAP maps every reading
  # into valid FHIR. Clinical values are preserved.
  def seed(m)
    seed_demographics(m)
    seed_clinical(m)
  end

  def seed_demographics(m)
    m.seed(:patient_select, "1", { name: "Anderson,Alice", sex: "F",
                                    dob: Date.parse("1980-05-15"), ssn: "111-11-1111", age: 45 })
    m.seed(:patient_id_info, "1", {
      ssn: "111-11-1111", dob: Date.parse("1980-05-15"), sex: "F",
      race_code: "I", site_ien: 7819, name: "Anderson,Alice"
    })
    m.seed(:patient_ssn, "111-11-1111", { dfn: 1, name: "Anderson,Alice", ssn: "111-11-1111" })
    m.seed_collection(:patient_list,
      [ { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15") } ],
      filter_field: :name)
  end

  def seed_clinical(m)
    # Problem list (ORQQPL LIST) — Condition
    m.seed_keyed_collection(:problem_list, "1",
      [ { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes mellitus" },
        { ien: 2, status: "A", icd_code: "I10", description: "Essential hypertension" },
        { ien: 3, status: "A", icd_code: "E78.5", description: "Hyperlipidemia" } ])

    # Allergies (ORQQAL LIST) — AllergyIntolerance
    m.seed_collection(:allergy_list,
      [ { ien: 1, allergen: "Penicillin", reaction: "Hives", severity: "moderate" },
        { ien: 2, allergen: "Shellfish", reaction: "Anaphylaxis", severity: "severe" } ])

    # Vitals — Observation, via the full verified Measurement.history
    # read graph: ORQQVI VITALS index (IEN^TYPE^DATETIME^VALUE, no units
    # on that wire) + per-measurement DDR core read + visit SERVICE
    # CATEGORY (BEHOENCX GETVISIT) + source units (BEHOVM2 VUNITS).
    # recorded_date feeds Observation.effectiveDateTime (required 1..1 by
    # the vital-signs profile); the V MEASUREMENT IEN is the FHIR id.
    vitals_taken = Time.utc(2026, 2, 1, 9, 30, 0)
    m.seed_keyed_collection(:vitals, "1",
      [ { measurement_ien: 7001, type: "BP", recorded_date: vitals_taken, value: "128/82" },
        { measurement_ien: 7002, type: "P",  recorded_date: vitals_taken, value: "74" },
        { measurement_ien: 7003, type: "WT", recorded_date: vitals_taken, value: "180" },
        { measurement_ien: 7004, type: "T",  recorded_date: vitals_taken, value: "98.6" } ])
    { 7001 => [ "BP", "128/82" ], 7002 => [ "PU", "74" ],
      7003 => [ "WT", "180" ], 7004 => [ "TMP", "98.6" ] }.each do |ien, (type, value)|
      seed_measurement_ddr(m, ien: ien, type: type, value: value,
                           date_internal: "3260201.093", date_display: "FEB 01, 2026@09:30")
    end
    m.seed(:encounter_visit, "9101", {
      location_ien: 1, datetime_raw: "3260201.093", service_category: "A",
      patient_dfn: 1, visit_id: "9101A", locked: false
    })
    { "BP" => "mmHg", "PU" => "/min", "WT" => "lb", "TMP" => "F" }.each do |type, us_unit|
      m.seed(:vital_units, type, { us_unit: us_unit, metric_unit: us_unit })
    end

    # Medications (ORQQPS LIST) — MedicationRequest
    m.seed_collection(:medication_list,
      [ { ien: 1, drug_name: "Lisinopril 10mg", sig: "1 tab PO daily", status: "active" },
        { ien: 2, drug_name: "Metformin 500mg", sig: "1 tab PO BID", status: "active" } ])
    m.seed(:medication_detail, "1",
      "Drug: Lisinopril 10mg\nSIG: Take 1 tablet by mouth daily\nStatus: Active\nRefills: 3")

    # Procedures (ORWPCE PROCEDURE LIST) — Procedure
    m.seed_collection(:procedure_list,
      [ { ien: 1, name: "Comprehensive metabolic panel", date: Date.new(2026, 1, 15), status: "completed" } ])

    # Appointments (ORWPT APPTLST) — Encounter
    m.seed_collection(:patient_appointments,
      [ { datetime: Date.new(2026, 2, 1), location_ien: 1,
          location: "Riverbend Family Health Clinic", status: "scheduled" } ])

    # Immunizations — structured list (BIPC IMMLIST) drives Immunization.for_patient;
    # the text summary (BEHOCIR GETTXT) is seeded too for parity with the RPC surface.
    m.seed_collection(:immunization_list,
      [ { ien: 1, vaccine_code: "208", vaccine_display: "COVID-19 Vaccine", status: "completed",
          lot_number: "LOT-ABC", site: "Left Deltoid", route: "Intramuscular",
          occurrence_datetime: DateTime.new(2026, 1, 15, 9, 0, 0), manufacturer: "Synthetic Bio" } ])
    m.seed(:immunization_text, "1",
      "01/15/2026  COVID-19 Vaccine  LOT-ABC  Site: Left Deltoid")
  end

  # Per-measurement DDR GETS ENTRY DATA reply (V MEASUREMENT #9000010.01:
  # .01 type / .02 patient / .03 visit / .04 value / 2 EIE / 1201 event
  # date-time) as GETSC^DDR2 formats it: "FILE^IEN^FIELD^INTERNAL^EXTERNAL".
  def seed_measurement_ddr(m, ien:, type:, value:, date_internal:, date_display:)
    key = RpmsRpc::DdrFileman.gets_entry_param(
      file: "9000010.01", iens: "#{ien},",
      fields: RpmsRpc::Measurement::CORE_FIELDS, flags: "IE"
    ).to_s
    m.seed(:ddr_gets_entry_data, key, <<~REPLY.chomp)
      [Data]
      9000010.01^#{ien}^.01^#{ien}^#{type}
      9000010.01^#{ien}^.02^1^ANDERSON,ALICE
      9000010.01^#{ien}^.03^9101^#{date_display}
      9000010.01^#{ien}^.04^#{value}^#{value}
      9000010.01^#{ien}^2^0^
      9000010.01^#{ien}^1201^#{date_internal}^#{date_display}
    REPLY
  end
end
