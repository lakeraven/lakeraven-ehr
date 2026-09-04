# frozen_string_literal: true

# Synthetic demo seed data for the read-only patient chart (issue #452),
# expanded to a small believable clinic panel for the local UIO demo.
#
# Single source of truth shared by:
#   * test/dummy/config/initializers/zz_spike_mock_rpc.rb  (dev, SPIKE-gated)
#   * the chart request test
#
# Seeds RpmsRpc's in-memory MockClient so the chart endpoint serves real
# FHIR reads through the engine's own gateways/models with NO live RPMS.
#
# SYNTHETIC DATA ONLY — invented patients (DFN 1 "Anderson, Alice" plus a
# DEMOPATIENT,* panel with 900-prefix pseudo-SSNs) and an invented facility
# ("Riverbend Family Health Clinic"). No PHI, no real person/tribe/org names.
module LakeravenDemoSeeds
  module_function

  # When the panel's vitals were taken (one recent clinic morning).
  VITALS_TAKEN = DateTime.new(2026, 8, 25, 9, 30, 0)

  # The demo panel: a small, clinically believable UIO clinic day.
  # Clustered chronic comorbidity (diabetes / hypertension / CKD), one
  # behavioral-health patient, one prenatal, one pediatric asthma.
  #
  # Vital `type` codes use RPMS-native abbreviations (BP/P/T/WT/HT) so the
  # engine's Observation.from_vital_hashes VITAL_TYPE_MAP maps every reading
  # into valid FHIR. BP carries both components in one reading ("systolic/
  # diastolic"), the shape the serializer expects.
  PANEL = [
    { dfn: 2, name: "DEMOPATIENT,HENRY", sex: "M", dob: Date.new(1954, 11, 22),
      ssn: "900-00-0102",
      problems: [
        { ien: 21, status: "A", icd_code: "I10",   description: "Essential hypertension" },
        { ien: 22, status: "A", icd_code: "N18.3", description: "Chronic kidney disease, stage 3" }
      ],
      medications: [
        { ien: 21, drug_name: "Lisinopril 20mg", sig: "1 tab PO daily", status: "active" },
        { ien: 22, drug_name: "Amlodipine 5mg",  sig: "1 tab PO daily", status: "active" }
      ],
      allergies: [
        { ien: 21, allergen: "Sulfa Drugs", reaction: "Rash", severity: "moderate" }
      ],
      vitals: [
        { type: "BP", value: "150/92", units: "mm[Hg]",  recorded_date: VITALS_TAKEN },
        { type: "P",  value: "68",     units: "/min",    recorded_date: VITALS_TAKEN },
        { type: "WT", value: "201",    units: "[lb_av]", recorded_date: VITALS_TAKEN }
      ] },
    { dfn: 3, name: "DEMOPATIENT,MARA", sex: "F", dob: Date.new(1997, 6, 30),
      ssn: "900-00-0103",
      problems: [
        { ien: 31, status: "A", icd_code: "Z34.83", description: "Supervision of normal pregnancy, third trimester" },
        { ien: 32, status: "A", icd_code: "D50.9",  description: "Iron deficiency anemia" }
      ],
      medications: [
        { ien: 31, drug_name: "Prenatal Vitamin", sig: "1 tab PO daily", status: "active" },
        { ien: 32, drug_name: "Ferrous Sulfate 325mg", sig: "1 tab PO daily", status: "active" }
      ],
      allergies: [],
      vitals: [
        { type: "BP", value: "112/70", units: "mm[Hg]",  recorded_date: VITALS_TAKEN },
        { type: "P",  value: "82",     units: "/min",    recorded_date: VITALS_TAKEN },
        { type: "WT", value: "158",    units: "[lb_av]", recorded_date: VITALS_TAKEN }
      ] },
    { dfn: 4, name: "DEMOPATIENT,JOE", sex: "M", dob: Date.new(1972, 1, 15),
      ssn: "900-00-0104",
      problems: [
        { ien: 41, status: "A", icd_code: "E11.65", description: "Type 2 diabetes mellitus with hyperglycemia" },
        { ien: 42, status: "A", icd_code: "E78.5",  description: "Hyperlipidemia" }
      ],
      medications: [
        { ien: 41, drug_name: "Metformin 1000mg",   sig: "1 tab PO BID",   status: "active" },
        { ien: 42, drug_name: "Atorvastatin 40mg",  sig: "1 tab PO qHS",   status: "active" }
      ],
      allergies: [],
      vitals: [
        { type: "BP", value: "136/84", units: "mm[Hg]",  recorded_date: VITALS_TAKEN },
        { type: "P",  value: "78",     units: "/min",    recorded_date: VITALS_TAKEN },
        { type: "WT", value: "224",    units: "[lb_av]", recorded_date: VITALS_TAKEN }
      ] },
    { dfn: 5, name: "DEMOPATIENT,TESSA", sex: "F", dob: Date.new(1990, 9, 8),
      ssn: "900-00-0105",
      problems: [
        { ien: 51, status: "A", icd_code: "F33.1", description: "Major depressive disorder, recurrent, moderate" },
        { ien: 52, status: "A", icd_code: "F41.1", description: "Generalized anxiety disorder" }
      ],
      medications: [
        { ien: 51, drug_name: "Sertraline 100mg", sig: "1 tab PO daily", status: "active" }
      ],
      allergies: [],
      vitals: [
        { type: "BP", value: "118/76", units: "mm[Hg]",  recorded_date: VITALS_TAKEN },
        { type: "P",  value: "72",     units: "/min",    recorded_date: VITALS_TAKEN },
        { type: "WT", value: "146",    units: "[lb_av]", recorded_date: VITALS_TAKEN }
      ] },
    { dfn: 6, name: "DEMOPATIENT,RAY", sex: "M", dob: Date.new(2016, 4, 12),
      ssn: "900-00-0106",
      problems: [
        { ien: 61, status: "A", icd_code: "J45.909", description: "Unspecified asthma, uncomplicated" }
      ],
      medications: [
        { ien: 61, drug_name: "Albuterol HFA 90mcg", sig: "2 puffs INH q4-6h PRN", status: "active" },
        { ien: 62, drug_name: "Fluticasone HFA 44mcg", sig: "2 puffs INH BID", status: "active" }
      ],
      allergies: [
        { ien: 61, allergen: "Peanuts", reaction: "Hives", severity: "moderate" }
      ],
      vitals: [
        { type: "P",  value: "96",   units: "/min",    recorded_date: VITALS_TAKEN },
        { type: "T",  value: "98.6", units: "[degF]",  recorded_date: VITALS_TAKEN },
        { type: "WT", value: "62",   units: "[lb_av]", recorded_date: VITALS_TAKEN }
      ] },
    { dfn: 7, name: "DEMOPATIENT,IRENE", sex: "F", dob: Date.new(1948, 2, 27),
      ssn: "900-00-0107",
      problems: [
        { ien: 71, status: "A", icd_code: "E11.9",  description: "Type 2 diabetes mellitus" },
        { ien: 72, status: "A", icd_code: "I10",    description: "Essential hypertension" },
        { ien: 73, status: "A", icd_code: "N18.3",  description: "Chronic kidney disease, stage 3" }
      ],
      medications: [
        { ien: 71, drug_name: "Metformin 500mg",   sig: "1 tab PO daily",  status: "active" },
        { ien: 72, drug_name: "Losartan 50mg",     sig: "1 tab PO daily",  status: "active" },
        { ien: 73, drug_name: "Atorvastatin 20mg", sig: "1 tab PO qHS",    status: "active" }
      ],
      allergies: [
        { ien: 71, allergen: "Codeine", reaction: "Nausea", severity: "mild" }
      ],
      vitals: [
        { type: "BP", value: "148/86", units: "mm[Hg]",  recorded_date: VITALS_TAKEN },
        { type: "P",  value: "70",     units: "/min",    recorded_date: VITALS_TAKEN },
        { type: "WT", value: "168",    units: "[lb_av]", recorded_date: VITALS_TAKEN }
      ] }
  ].freeze

  # Seed a MockClient (`m`) with demographics + clinical data for the panel.
  def seed(m)
    seed_demographics(m)
    seed_clinical(m)
    seed_panel(m)
  end

  def seed_demographics(m)
    m.seed(:patient_select, "1", { name: "Anderson,Alice", sex: "F",
                                    dob: Date.parse("1980-05-15"), ssn: "111-11-1111", age: 45 })
    m.seed(:patient_id_info, "1", {
      ssn: "111-11-1111", dob: Date.parse("1980-05-15"), sex: "F",
      race_code: "I", site_ien: 7819, name: "Anderson,Alice"
    })
    m.seed(:patient_ssn, "111-11-1111", { dfn: 1, name: "Anderson,Alice", ssn: "111-11-1111" })

    # Patient search (lookup/select beat): Alice + the whole DEMOPATIENT panel.
    panel_rows = PANEL.map { |p| { dfn: p[:dfn], name: p[:name], sex: p[:sex], dob: p[:dob] } }
    m.seed_collection(:patient_list,
      [ { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15") } ] + panel_rows,
      filter_field: :name)
  end

  def seed_clinical(m)
    # Problem list (ORQQPL LIST) — Condition
    m.seed_keyed_collection(:problem_list, "1",
      [ { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes mellitus" },
        { ien: 2, status: "A", icd_code: "I10", description: "Essential hypertension" },
        { ien: 3, status: "A", icd_code: "E78.5", description: "Hyperlipidemia" } ])

    # Allergies (ORQQAL LIST) — AllergyIntolerance
    m.seed_keyed_collection(:allergy_list, "1",
      [ { ien: 1, allergen: "Penicillin", reaction: "Hives", severity: "moderate" },
        { ien: 2, allergen: "Shellfish", reaction: "Anaphylaxis", severity: "severe" } ])

    # Vitals (ORQQVI VITALS) — Observation. recorded_date feeds
    # Observation.effectiveDateTime (required 1..1 by the vital-signs
    # profile) and the deterministic per-vital FHIR id.
    vitals_taken = DateTime.new(2026, 2, 1, 9, 30, 0)
    m.seed_keyed_collection(:vitals, "1",
      [ { type: "BP", value: "128/82", units: "mm[Hg]",   recorded_date: vitals_taken },
        { type: "P",  value: "74",     units: "/min",     recorded_date: vitals_taken },
        { type: "WT", value: "180",    units: "[lb_av]",  recorded_date: vitals_taken },
        { type: "T",  value: "98.6",   units: "[degF]",   recorded_date: vitals_taken } ])

    # Medications (ORQQPS LIST) — MedicationRequest
    m.seed_keyed_collection(:medication_list, "1",
      [ { ien: 1, drug_name: "Lisinopril 10mg", sig: "1 tab PO daily", status: "active" },
        { ien: 2, drug_name: "Metformin 500mg", sig: "1 tab PO BID", status: "active" } ])
    m.seed(:medication_detail, "1",
      "Drug: Lisinopril 10mg\nSIG: Take 1 tablet by mouth daily\nStatus: Active\nRefills: 3")

    # Procedures (ORWPCE PROCEDURE LIST) — Procedure
    m.seed_keyed_collection(:procedure_list, "1",
      [ { ien: 1, name: "Comprehensive metabolic panel", date: Date.new(2026, 1, 15), status: "completed" } ])

    # Appointments (ORWPT APPTLST) — Encounter
    m.seed_keyed_collection(:patient_appointments, "1",
      [ { datetime: Date.new(2026, 2, 1), location_ien: 1,
          location: "Riverbend Family Health Clinic", status: "scheduled" } ])

    # Immunizations — structured list (BIPC IMMLIST) drives Immunization.for_patient;
    # the text summary (BEHOCIR GETTXT) is seeded too for parity with the RPC surface.
    m.seed_keyed_collection(:immunization_list, "1",
      [ { ien: 1, vaccine_code: "208", vaccine_display: "COVID-19 Vaccine", status: "completed",
          lot_number: "LOT-ABC", site: "Left Deltoid", route: "Intramuscular",
          occurrence_datetime: DateTime.new(2026, 1, 15, 9, 0, 0), manufacturer: "Synthetic Bio" } ])
    m.seed(:immunization_text, "1",
      "01/15/2026  COVID-19 Vaccine  LOT-ABC  Site: Left Deltoid")
  end

  # Seed the DEMOPATIENT panel (DFNs 2-7) — demographics + per-patient
  # clinical lists keyed by DFN so each chart renders its own data.
  def seed_panel(m)
    PANEL.each do |p|
      dfn = p[:dfn].to_s
      age = ((Date.new(2026, 8, 25) - p[:dob]) / 365.25).floor

      m.seed(:patient_select, dfn, { name: p[:name], sex: p[:sex],
                                      dob: p[:dob], ssn: p[:ssn], age: age })
      m.seed(:patient_id_info, dfn, {
        ssn: p[:ssn], dob: p[:dob], sex: p[:sex],
        race_code: "I", site_ien: 7819, name: p[:name]
      })
      m.seed(:patient_ssn, p[:ssn], { dfn: p[:dfn], name: p[:name], ssn: p[:ssn] })

      m.seed_keyed_collection(:problem_list, dfn, p[:problems])
      m.seed_keyed_collection(:medication_list, dfn, p[:medications])
      m.seed_keyed_collection(:allergy_list, dfn, p[:allergies])
      m.seed_keyed_collection(:vitals, dfn, p[:vitals])

      # Every panel member has a chart-able clinic-day encounter.
      m.seed_keyed_collection(:patient_appointments, dfn,
        [ { datetime: Date.new(2026, 9, 3), location_ien: 1,
            location: "Riverbend Family Health Clinic", status: "scheduled" } ])

      # Keep sections that would otherwise fall through to another patient's
      # unkeyed data explicitly empty instead.
      m.seed_keyed_collection(:procedure_list, dfn, [])
      m.seed_keyed_collection(:immunization_list, dfn, [])
    end
  end
end
