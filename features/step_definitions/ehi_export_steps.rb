# frozen_string_literal: true

# ONC § 170.315(b)(10) — Electronic Health Information Export step definitions
# Covers single-patient EHI export, non-FHIR data, manifest, and formats.

# -----------------------------------------------------------------------------
# Given: patient data and audit events
# -----------------------------------------------------------------------------

Given("the patient has clinical data for EHI export") do
  @patient_dfn ||= "12345"

  # Save original methods so we can restore them after the scenario
  @_original_find_by_dfn = Lakeraven::EHR::Patient.method(:find_by_dfn)
  @_original_allergy_for_patient = Lakeraven::EHR::AllergyIntolerance.method(:for_patient)
  @_original_med_for_patient = Lakeraven::EHR::MedicationRequest.method(:for_patient)

  # Stub Patient.find_by_dfn to return a patient with clinical data
  Lakeraven::EHR::Patient.define_singleton_method(:find_by_dfn) do |dfn|
    patient = Lakeraven::EHR::Patient.new(dfn: dfn.to_i, name: "Anderson,Alice", sex: "F", dob: 50.years.ago.to_date)
    patient.instance_variable_set(:@problem_list, [])
    patient
  end

  # Stub clinical data sources
  Lakeraven::EHR::AllergyIntolerance.define_singleton_method(:for_patient) do |_dfn|
    [
      Lakeraven::EHR::AllergyIntolerance.new(ien: "allergy-1", patient_dfn: "12345",
        allergen_code: "7980", allergen: "Penicillin", clinical_status: "active"),
      Lakeraven::EHR::AllergyIntolerance.new(ien: "allergy-2", patient_dfn: "12345",
        allergen_code: "36567", allergen: "Simvastatin", clinical_status: "active")
    ]
  end

  Lakeraven::EHR::MedicationRequest.define_singleton_method(:for_patient) do |_dfn, **_opts|
    [
      Lakeraven::EHR::MedicationRequest.new(ien: "med-1", patient_dfn: "12345",
        medication_code: "197884", medication_display: "Lisinopril 10 MG", status: "active", intent: "order")
    ]
  end

  @ehi_conditions = [
    { code: "E11.9", display: "Type 2 diabetes mellitus", status: "active" }
  ]

  @ehi_observations = [
    { code: "8480-6", display: "Systolic BP", value: "120", units: "mm[Hg]" }
  ]
end

Given("audit events exist for the patient") do
  @audit_events_created = true
  # Create real audit events in the database
  Lakeraven::EHR::AuditEvent.create!(
    event_type: "rest", action: "R", outcome: "0",
    agent_who_type: "Practitioner", agent_who_identifier: "789",
    entity_type: "Patient", entity_identifier: "12345",
    outcome_desc: "Patient demographics accessed"
  )
  Lakeraven::EHR::AuditEvent.create!(
    event_type: "rest", action: "R", outcome: "0",
    agent_who_type: "Practitioner", agent_who_identifier: "789",
    entity_type: "AllergyIntolerance", entity_identifier: "12345",
    outcome_desc: "Allergy data accessed for patient 12345"
  )
end

# -----------------------------------------------------------------------------
# When: EHI export
# -----------------------------------------------------------------------------

When("a single-patient EHI export is requested") do
  @ehi_export = Lakeraven::EHR::EhiExportService.new(patient_dfn: @patient_dfn).export
end

When("a single-patient EHI export is requested with a date range") do
  @ehi_export = Lakeraven::EHR::EhiExportService.new(
    patient_dfn: @patient_dfn,
    since: 30.days.ago,
    before: Time.current
  ).export
end

When("a single-patient EHI export is requested with timing") do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @ehi_export = Lakeraven::EHR::EhiExportService.new(patient_dfn: @patient_dfn).export
  @generation_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

# -----------------------------------------------------------------------------
# Then: export structure
# -----------------------------------------------------------------------------

Then("the export should complete successfully") do
  assert @ehi_export[:success], "Expected successful export: #{@ehi_export[:errors]}"
end

Then("the export should contain FHIR clinical resources") do
  assert @ehi_export[:files].any? { |f| f[:type] == "fhir_ndjson" },
    "Expected FHIR NDJSON files in export"
end

Then("the export should contain audit log entries") do
  audit_file = @ehi_export[:files].find { |f| f[:name] =~ /audit/ }
  assert audit_file.present?, "Expected audit log file in export"
end

Then("the export should contain a manifest file") do
  manifest = @ehi_export[:files].find { |f| f[:name] == "manifest.json" }
  assert manifest.present?, "Expected manifest.json in export"
end

# Then: FHIR resource types

Then("the export should include Patient resources") do
  patient_file = @ehi_export[:files].find { |f| f[:name] =~ /patient/i && f[:type] == "fhir_ndjson" }
  assert patient_file.present?, "Expected Patient NDJSON file"
  assert patient_file[:count].positive?, "Expected at least 1 Patient resource"
end

Then("the export should include AllergyIntolerance resources") do
  file = @ehi_export[:files].find { |f| f[:name] == "allergy_intolerance.ndjson" }
  assert file.present?, "Expected AllergyIntolerance NDJSON file"
end

Then("the export should include Condition resources") do
  file = @ehi_export[:files].find { |f| f[:name] == "condition.ndjson" }
  assert file.present?, "Expected Condition NDJSON file"
end

Then("the export should include MedicationRequest resources") do
  file = @ehi_export[:files].find { |f| f[:name] == "medication_request.ndjson" }
  assert file.present?, "Expected MedicationRequest NDJSON file"
end

Then("the export should include Observation resources") do
  file = @ehi_export[:files].find { |f| f[:name] == "observation.ndjson" }
  assert file.present?, "Expected Observation NDJSON file"
end

# Then: non-FHIR data

Then("the export should contain an audit log CSV") do
  audit_file = @ehi_export[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
  assert audit_file.present?, "Expected audit log CSV file"
end

Then("the audit log should include patient-related events") do
  audit_file = @ehi_export[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
  assert audit_file[:count].positive?, "Expected audit events for patient"
end

Then("the export should contain a configuration summary") do
  config_file = @ehi_export[:files].find { |f| f[:name] =~ /configuration/ }
  assert config_file.present?, "Expected configuration summary in export"
end

Then("the configuration summary should document data sources") do
  config_file = @ehi_export[:files].find { |f| f[:name] =~ /configuration/ }
  assert config_file[:content].present?, "Expected configuration content"
  assert config_file[:content].include?("data_sources"), "Expected data_sources in configuration"
end

# Then: manifest

Then("the manifest should list all included files") do
  manifest = @ehi_export[:files].find { |f| f[:name] == "manifest.json" }
  parsed = JSON.parse(manifest[:content])
  assert parsed["files"].is_a?(Array), "Expected files array in manifest"
  assert parsed["files"].length > 1, "Expected multiple files listed"
end

Then("the manifest should describe the export format") do
  manifest = @ehi_export[:files].find { |f| f[:name] == "manifest.json" }
  parsed = JSON.parse(manifest[:content])
  assert parsed["format"].present?, "Expected format description"
end

Then("the manifest should include the export timestamp") do
  manifest = @ehi_export[:files].find { |f| f[:name] == "manifest.json" }
  parsed = JSON.parse(manifest[:content])
  assert parsed["exported_at"].present?, "Expected export timestamp"
end

Then("the manifest should reference ONC certification criterion") do
  manifest = @ehi_export[:files].find { |f| f[:name] == "manifest.json" }
  parsed = JSON.parse(manifest[:content])
  assert parsed["certification_criterion"].present?, "Expected ONC criterion reference"
  assert_match(/170\.315/, parsed["certification_criterion"])
end

# Then: formats

Then("each FHIR resource file should be valid NDJSON") do
  fhir_files = @ehi_export[:files].select { |f| f[:type] == "fhir_ndjson" }
  assert fhir_files.any?, "Expected FHIR NDJSON files"
  # Files with data should have content; empty files (0 resources) are valid
  populated = fhir_files.select { |f| f[:count].positive? }
  assert populated.any?, "Expected at least one FHIR file with content"
end

Then("each NDJSON line should be valid JSON") do
  fhir_files = @ehi_export[:files].select { |f| f[:type] == "fhir_ndjson" && f[:count].positive? }
  fhir_files.each do |file|
    file[:content].each_line do |line|
      next if line.strip.empty?
      parsed = JSON.parse(line)
      assert parsed.is_a?(Hash), "Expected JSON object on each line"
    end
  end
end

Then("the audit log file should be valid CSV") do
  audit_file = @ehi_export[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
  assert audit_file[:content].present?, "Expected CSV content"
  rows = CSV.parse(audit_file[:content])
  assert rows.length > 1, "Expected header + data rows"
end

Then("the CSV should include column headers") do
  audit_file = @ehi_export[:files].find { |f| f[:name] =~ /audit.*\.csv/ }
  rows = CSV.parse(audit_file[:content])
  headers = rows.first
  assert headers.include?("Timestamp"), "Expected Timestamp header"
  assert headers.include?("Action"), "Expected Action header"
end

# Then: filtering

Then("the export should only include data within the date range") do
  assert @ehi_export[:success], "Expected successful filtered export"
  manifest = @ehi_export[:files].find { |f| f[:name] == "manifest.json" }
  parsed = JSON.parse(manifest[:content])
  assert parsed["filters"].present?, "Expected filters in manifest"
end

# Then: performance

Then("the export should complete in under {int} seconds") do |max_seconds|
  assert @generation_elapsed < max_seconds,
    "EHI export took #{@generation_elapsed.round(3)}s, expected < #{max_seconds}s"
end

# Restore original class methods that were stubbed for EHI export scenarios.
After do
  if @_original_find_by_dfn
    Lakeraven::EHR::Patient.define_singleton_method(:find_by_dfn, @_original_find_by_dfn)
    @_original_find_by_dfn = nil
  end
  if @_original_allergy_for_patient
    Lakeraven::EHR::AllergyIntolerance.define_singleton_method(:for_patient, @_original_allergy_for_patient)
    @_original_allergy_for_patient = nil
  end
  if @_original_med_for_patient
    Lakeraven::EHR::MedicationRequest.define_singleton_method(:for_patient, @_original_med_for_patient)
    @_original_med_for_patient = nil
  end
end
