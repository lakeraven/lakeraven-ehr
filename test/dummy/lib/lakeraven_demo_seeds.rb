# frozen_string_literal: true

# Synthetic demo data for the read-only patient chart (issue #452), expanded
# to a small believable clinic panel for the local demo.
#
# Single source of truth shared by:
#   * test/dummy/config/initializers/zz_spike_mock_rpc.rb  (dev, SPIKE-gated)
#   * the chart request tests
#
# It answers the engine's stand-in for RPMS (test/support/rpms_stand_in.rb):
# each fact is what the rpms-rpc method the engine's gateways call returns, so
# the chart endpoint serves real FHIR reads through the engine's own gateways
# and models with NO live RPMS.
#
# SYNTHETIC DATA ONLY: invented patients (DFN 1 "Anderson, Alice" plus a
# DEMOPATIENT,* panel with 900-prefix pseudo-SSNs) and an invented facility
# ("Riverbend Family Health Clinic"). No PHI, no real person or organization names.
module LakeravenDemoSeeds
  module_function

  # When the panel's vitals were taken (one recent clinic morning).
  VITALS_TAKEN = Time.new(2026, 8, 25, 9, 30, 0)

  # The demo panel: a small, clinically believable UIO clinic day.
  # Clustered chronic comorbidity (diabetes / hypertension / CKD), one
  # behavioral-health patient, one prenatal, one pediatric asthma.
  #
  # Vitals are as RpmsRpc::Vital.for_patient returns them on RPMS: IHS MEASUREMENT TYPE
  # codes (BP, PU, WT; TMP, RS, O2 for the others), the recorded text in
  # display, and no units piece (the reply has none). The engine's
  # Observation.from_vital_hashes VITAL_TYPE_MAP maps each into valid FHIR. BP carries both components in one reading ("systolic/
  # diastolic"), the shape the serializer expects.
  PANEL = [
    { dfn: 2, name: "DEMOPATIENT,HENRY", sex: "M", dob: Date.new(1954, 11, 22),
      ssn: "900-00-0102",
      problems: [
        { ien: 21, status: "A", icd_code: "I10",   description: "Essential hypertension" },
        { ien: 22, status: "A", icd_code: "N18.3", description: "Chronic kidney disease, stage 3" }
      ],
      medications: [
        { id: "21", name: "Lisinopril 20mg", sig: "1 tab PO daily", status: "ACTIVE" },
        { id: "22", name: "Amlodipine 5mg",  sig: "1 tab PO daily", status: "ACTIVE" }
      ],
      allergies: [
        { ien: 21, allergen: "Sulfa Drugs", reaction: "Rash", severity: "moderate" }
      ],
      vitals: [
        { measurement_ien: 2001, type: "BP", value: "150/92", recorded_date: VITALS_TAKEN, display: "150/92" },
        { measurement_ien: 2002, type: "PU", value: "68", recorded_date: VITALS_TAKEN, display: "68" },
        { measurement_ien: 2003, type: "WT", value: "201", recorded_date: VITALS_TAKEN, display: "201" }
      ] },
    { dfn: 3, name: "DEMOPATIENT,MARA", sex: "F", dob: Date.new(1997, 6, 30),
      ssn: "900-00-0103",
      problems: [
        { ien: 31, status: "A", icd_code: "Z34.83", description: "Supervision of normal pregnancy, third trimester" },
        { ien: 32, status: "A", icd_code: "D50.9",  description: "Iron deficiency anemia" }
      ],
      medications: [
        { id: "31", name: "Prenatal Vitamin", sig: "1 tab PO daily", status: "ACTIVE" },
        { id: "32", name: "Ferrous Sulfate 325mg", sig: "1 tab PO daily", status: "ACTIVE" }
      ],
      allergies: [],
      vitals: [
        { measurement_ien: 2004, type: "BP", value: "112/70", recorded_date: VITALS_TAKEN, display: "112/70" },
        { measurement_ien: 2005, type: "PU", value: "82", recorded_date: VITALS_TAKEN, display: "82" },
        { measurement_ien: 2006, type: "WT", value: "158", recorded_date: VITALS_TAKEN, display: "158" }
      ] },
    { dfn: 4, name: "DEMOPATIENT,JOE", sex: "M", dob: Date.new(1972, 1, 15),
      ssn: "900-00-0104",
      problems: [
        { ien: 41, status: "A", icd_code: "E11.65", description: "Type 2 diabetes mellitus with hyperglycemia" },
        { ien: 42, status: "A", icd_code: "E78.5",  description: "Hyperlipidemia" }
      ],
      medications: [
        { id: "41", name: "Metformin 1000mg",   sig: "1 tab PO BID",   status: "ACTIVE" },
        { id: "42", name: "Atorvastatin 40mg",  sig: "1 tab PO qHS",   status: "ACTIVE" }
      ],
      allergies: [],
      vitals: [
        { measurement_ien: 2007, type: "BP", value: "136/84", recorded_date: VITALS_TAKEN, display: "136/84" },
        { measurement_ien: 2008, type: "PU", value: "78", recorded_date: VITALS_TAKEN, display: "78" },
        { measurement_ien: 2009, type: "WT", value: "224", recorded_date: VITALS_TAKEN, display: "224" }
      ] },
    { dfn: 5, name: "DEMOPATIENT,TESSA", sex: "F", dob: Date.new(1990, 9, 8),
      ssn: "900-00-0105",
      problems: [
        { ien: 51, status: "A", icd_code: "F33.1", description: "Major depressive disorder, recurrent, moderate" },
        { ien: 52, status: "A", icd_code: "F41.1", description: "Generalized anxiety disorder" }
      ],
      medications: [
        { id: "51", name: "Sertraline 100mg", sig: "1 tab PO daily", status: "ACTIVE" }
      ],
      allergies: [],
      vitals: [
        { measurement_ien: 2010, type: "BP", value: "118/76", recorded_date: VITALS_TAKEN, display: "118/76" },
        { measurement_ien: 2011, type: "PU", value: "72", recorded_date: VITALS_TAKEN, display: "72" },
        { measurement_ien: 2012, type: "WT", value: "146", recorded_date: VITALS_TAKEN, display: "146" }
      ] },
    { dfn: 6, name: "DEMOPATIENT,RAY", sex: "M", dob: Date.new(2016, 4, 12),
      ssn: "900-00-0106",
      problems: [
        { ien: 61, status: "A", icd_code: "J45.909", description: "Unspecified asthma, uncomplicated" }
      ],
      medications: [
        { id: "61", name: "Albuterol HFA 90mcg", sig: "2 puffs INH q4-6h PRN", status: "ACTIVE" },
        { id: "62", name: "Fluticasone HFA 44mcg", sig: "2 puffs INH BID", status: "ACTIVE" }
      ],
      allergies: [
        { ien: 61, allergen: "Peanuts", reaction: "Hives", severity: "moderate" }
      ],
      vitals: [
        { measurement_ien: 2013, type: "PU", value: "96", recorded_date: VITALS_TAKEN, display: "96" },
        { measurement_ien: 2014, type: "TMP", value: "98.6", recorded_date: VITALS_TAKEN, display: "98.6 F", metric_display: "(37.0 C)" },
        { measurement_ien: 2015, type: "WT", value: "62", recorded_date: VITALS_TAKEN, display: "62" }
      ] },
    { dfn: 7, name: "DEMOPATIENT,IRENE", sex: "F", dob: Date.new(1948, 2, 27),
      ssn: "900-00-0107",
      problems: [
        { ien: 71, status: "A", icd_code: "E11.9",  description: "Type 2 diabetes mellitus" },
        { ien: 72, status: "A", icd_code: "I10",    description: "Essential hypertension" },
        { ien: 73, status: "A", icd_code: "N18.3",  description: "Chronic kidney disease, stage 3" }
      ],
      medications: [
        { id: "71", name: "Metformin 500mg",   sig: "1 tab PO daily",  status: "ACTIVE" },
        { id: "72", name: "Losartan 50mg",     sig: "1 tab PO daily",  status: "ACTIVE" },
        { id: "73", name: "Atorvastatin 20mg", sig: "1 tab PO qHS",    status: "ACTIVE" }
      ],
      allergies: [
        { ien: 71, allergen: "Codeine", reaction: "Nausea", severity: "mild" }
      ],
      vitals: [
        { measurement_ien: 2016, type: "BP", value: "148/86", recorded_date: VITALS_TAKEN, display: "148/86" },
        { measurement_ien: 2017, type: "PU", value: "70", recorded_date: VITALS_TAKEN, display: "70" },
        { measurement_ien: 2018, type: "WT", value: "168", recorded_date: VITALS_TAKEN, display: "168" }
      ] }
  ].freeze

  # Answer the stand-in (`rpms`, RpmsStandIn) with demographics and clinical
  # data for the panel.
  def seed(rpms)
    patients = { 1 => ALICE }.merge(PANEL.to_h { |p| [ p[:dfn], p ] })
    seed_demographics(rpms, patients)
    seed_alice(rpms)
    PANEL.each { |p| seed_panel_member(rpms, p) }
    # Opening a record asks RPMS whether it is sensitive first (#613), and an
    # unanswered check never opens it. Every demo patient answers 0.
    rpms.not_sensitive(*patients.keys)
  end

  ALICE = { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.new(1980, 5, 15), ssn: "111-11-1111", age: 45 }.freeze
  CLINIC = "Riverbend Family Health Clinic"

  def seed_demographics(rpms, patients)
    patients.each do |dfn, p|
      age = p[:age] || ((Date.new(2026, 8, 25) - p[:dob]) / 365.25).floor
      rpms.answer(RpmsRpc::Patient, :find, dfn, with: p.slice(:name, :sex, :dob, :ssn).merge(age: age, dfn: dfn))
    end
    # The SSN index holds the SSN without punctuation and no date of birth.
    by_ssn = patients.to_h { |dfn, p| [ p[:ssn].delete("-"), { dfn: dfn, name: p[:name], dob: nil, ssn: p[:ssn].delete("-") } ] }
    rpms.answer(RpmsRpc::Patient, :find_by_ssn) { |ssn| by_ssn[ssn.to_s.delete("^0-9")]&.dup }
    # Patient search (lookup/select beat): Alice and the whole DEMOPATIENT
    # panel, as the one page of the name index a search reads.
    rpms.answer(RpmsRpc::Patient, :search) { |*| patients.map { |dfn, p| { dfn: dfn, name: p[:name] } } }
  end

  def seed_alice(rpms)
    seed_chart(rpms, 1,
      problems: [ { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes mellitus" },
                  { ien: 2, status: "A", icd_code: "I10", description: "Essential hypertension" },
                  { ien: 3, status: "A", icd_code: "E78.5", description: "Hyperlipidemia" } ],
      allergies: [ { ien: 1, allergen: "Penicillin", severity: "moderate" },
                   { ien: 2, allergen: "Shellfish", severity: "severe" } ],
      # recorded_date feeds Observation.effectiveDateTime (required 1..1 by the
      # vital-signs profile) and the deterministic per-vital FHIR id.
      vitals: [ { measurement_ien: 2019, type: "BP", value: "128/82", recorded_date: Time.new(2026, 2, 1, 9, 30, 0), display: "128/82" },
                { measurement_ien: 2020, type: "PU", value: "74", recorded_date: Time.new(2026, 2, 1, 9, 30, 0), display: "74" },
                { measurement_ien: 2021, type: "WT", value: "180", recorded_date: Time.new(2026, 2, 1, 9, 30, 0), display: "180" },
                { measurement_ien: 2022, type: "TMP", value: "98.6", recorded_date: Time.new(2026, 2, 1, 9, 30, 0), display: "98.6 F", metric_display: "(37.0 C)" } ],
      medications: [ { id: "1", name: "Lisinopril 10mg", sig: "1 tab PO daily", status: "ACTIVE" },
                     { id: "2", name: "Metformin 500mg", sig: "1 tab PO BID", status: "ACTIVE" } ],
      appointment_on: Date.new(2026, 2, 1),
      visit: { datetime: Time.new(2026, 1, 15, 9, 0, 0), visit_ien: 1, provider_ien: 101, provider: "MARTINEZ,SARAH" })

    # Procedures (V CPT). V CPT carries no status.
    rpms.answer(RpmsRpc::Procedure, :for_patient, 1,
      with: [ { ien: "1", visit_ien: "1", date: Date.new(2026, 1, 15), cpt_code: "80053", name: "Comprehensive metabolic panel" } ])
    # The visit's diagnosis.
    rpms.answer(RpmsRpc::Pov, :for_patient, 1,
      with: [ { ien: "1", visit_ien: "1", visit_date: "01/15/2026", icd_code: "I10.",
                icd_name: "Essential (primary) hypertension", narrative: "HYPERTENSION" } ])
    rpms.answer(RpmsRpc::Immunization, :for_patient, 1,
      with: [ { ien: "1", vaccine_display: "COVID-19 Vaccine", lot_number: "LOT-ABC", site: "Left Deltoid",
                occurrence_datetime: Time.new(2026, 1, 15, 9, 0, 0), manufacturer: "Synthetic Bio" } ])
  end

  # A DEMOPATIENT panel member (DFNs 2-7): each chart renders its own data,
  # and every member has a chart-able clinic-day encounter.
  def seed_panel_member(rpms, p)
    seed_chart(rpms, p[:dfn], problems: p[:problems], allergies: p[:allergies], vitals: p[:vitals],
               medications: p[:medications], appointment_on: Date.new(2026, 9, 3),
               visit: { datetime: Time.new(2026, 9, 3, 9, 0, 0), visit_ien: p[:dfn] })
  end

  # One patient's lists, each as the rpms-rpc read the gateway makes returns it.
  def seed_chart(rpms, dfn, problems:, allergies:, vitals:, medications:, appointment_on:, visit:)
    rpms.answer(RpmsRpc::Problem, :for_patient, dfn,
      with: problems.map { |row| row.merge(ien: row[:ien].to_s, inactive_icd: false) })
    rows = allergies.map { |row| row.slice(:ien, :allergen, :severity).merge(ien: row[:ien].to_s, signs: nil, altered: false) }
    rpms.answer(RpmsRpc::Allergy, :assessment, dfn, with: { assessed: rows.any?, nka: false, allergies: rows })
    rpms.answer(RpmsRpc::Vital, :for_patient, dfn, with: vitals.map(&:dup))
    rpms.answer(RpmsRpc::Medication, :active_for_patient, dfn, with: medications.map { |med| active_medication(med) })
    rpms.answer(RpmsRpc::Encounter, :for_patient, dfn,
      with: [ { datetime: appointment_on, location_ien: 1, location: CLINIC, status: "scheduled" } ])
    rpms.answer(RpmsRpc::Encounter, :visits, dfn,
      with: [ { location: CLINIC, category: "AMBULATORY", location_ien: 1, service_category: "A" }.merge(visit) ])
  end

  # An outpatient order as RpmsRpc::Medication.active_for_patient returns it:
  # the order id, the drug, its status, and the sig as its instruction line.
  def active_medication(med)
    { order_id: "#{med[:id]}R;O", type: "OP", name: med[:name], status: med[:status], stop_date: nil,
      instructions: [ "Sig: #{med[:sig]}" ], comments: [] }
  end
end
