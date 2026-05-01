# frozen_string_literal: true

# ONC § 170.315(f)(3) — Electronic Laboratory Reporting step definitions
# Covers reportable lab triggers, HL7 ORU generation, ECLRS transmission.
#
# Shared steps NOT redefined here:
#   "a patient exists with DFN {string}" — cpoe_steps.rb
#   "the generation should complete in under {int} seconds" — electronic_prescribing_steps.rb

# -----------------------------------------------------------------------------
# Given: lab results and clinical data
# -----------------------------------------------------------------------------

Given("the patient has a lab result with LOINC {string} for {string}") do |loinc_code, display|
  @lab_observation = Lakeraven::EHR::Observation.new(
    ien: "lab-#{SecureRandom.hex(4)}",
    patient_dfn: @patient_dfn || "12345",
    category: "laboratory",
    code: loinc_code,
    code_system: "http://loinc.org",
    display: display,
    value: "Positive",
    value_quantity: nil,
    unit: nil,
    status: "final",
    effective_datetime: Time.current
  )
end

Given("the patient has clinical data for the lab report") do
  @lab_report_data = {
    patient: {
      dfn: @patient_dfn || "12345",
      name: { given: "Alice", family: "Anderson" },
      dob: "1975-06-15", sex: "F",
      address: { street: "123 Main St", city: "Kingston", state: "NY", zip: "12401" }
    },
    ordering_provider: {
      duz: "789", name: "Dr. Smith", npi: "1234567890"
    },
    performing_lab: {
      name: "Ulster County Lab", clia: "33D1234567"
    },
    specimen: {
      type: "BLD", type_display: "Blood", collected_at: Time.current
    }
  }
end

Given("the lab result has organism {string} coded as SNOMED {string}") do |organism_display, snomed_code|
  @organism = { display: organism_display, code: snomed_code, code_system: "http://snomed.info/sct" }
end

Given("an HL7 ORU message has been generated") do
  @oru_message = Lakeraven::EHR::Elr::OruMessageGenerator.generate(
    observation: @lab_observation,
    patient: @lab_report_data[:patient],
    ordering_provider: @lab_report_data[:ordering_provider],
    performing_lab: @lab_report_data[:performing_lab],
    specimen: @lab_report_data[:specimen]
  )
end

# -----------------------------------------------------------------------------
# When: trigger evaluation and ORU generation
# -----------------------------------------------------------------------------

When("the lab result is evaluated for reportability") do
  @lab_reportability = Lakeraven::EHR::ReportableLabService.evaluate(@lab_observation)
end

When("the reportable lab tests list is loaded") do
  @reportable_labs_list = Lakeraven::EHR::ReportableLabService.all_tests
end

When("an HL7 ORU message is generated for the lab result") do
  @oru_message = Lakeraven::EHR::Elr::OruMessageGenerator.generate(
    observation: @lab_observation,
    patient: @lab_report_data[:patient],
    ordering_provider: @lab_report_data[:ordering_provider],
    performing_lab: @lab_report_data[:performing_lab],
    specimen: @lab_report_data[:specimen],
    organism: @organism
  )
end

When("an HL7 ORU message is generated with timing") do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @oru_message = Lakeraven::EHR::Elr::OruMessageGenerator.generate(
    observation: @lab_observation,
    patient: @lab_report_data[:patient],
    ordering_provider: @lab_report_data[:ordering_provider],
    performing_lab: @lab_report_data[:performing_lab],
    specimen: @lab_report_data[:specimen]
  )
  @generation_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

When("the ORU message is transmitted to ECLRS") do
  adapter = Lakeraven::EHR::Elr::MockEclrsAdapter.new
  @elr_service = Lakeraven::EHR::Elr::EclrsTransmissionService.new(adapter: adapter)
  @elr_result = @elr_service.submit(
    oru_message: @oru_message,
    patient_dfn: @patient_dfn || "12345",
    provider_duz: "789"
  )
end

# -----------------------------------------------------------------------------
# Then: trigger results
# -----------------------------------------------------------------------------

Then("the lab should be flagged as reportable") do
  assert @lab_reportability[:reportable], "Expected lab to be reportable"
end

Then("the lab should not be flagged as reportable") do
  refute @lab_reportability[:reportable], "Expected lab to NOT be reportable"
end

Then("the trigger should reference the reportable lab tests list") do
  assert @lab_reportability[:trigger_source].present?, "Expected trigger source reference"
end

Then("the list should include hepatitis B surface antigen") do
  codes = @reportable_labs_list.map { |t| t[:loinc] }
  assert codes.include?("11585-7"), "Expected HBsAg LOINC 11585-7"
end

Then("the list should include HIV viral load") do
  codes = @reportable_labs_list.map { |t| t[:loinc] }
  assert codes.any? { |c| c.start_with?("20447") || c == "20447-9" }, "Expected HIV viral load"
end

Then("the list should include chlamydia NAAT") do
  codes = @reportable_labs_list.map { |t| t[:loinc] }
  assert codes.any? { |c| c.start_with?("21613") || c == "21613-5" }, "Expected chlamydia NAAT"
end

Then("the list should include gonorrhea culture") do
  codes = @reportable_labs_list.map { |t| t[:loinc] }
  assert codes.any? { |c| c.start_with?("688") || c == "688-2" }, "Expected gonorrhea culture"
end

Then("the list should include blood lead level") do
  codes = @reportable_labs_list.map { |t| t[:loinc] }
  assert codes.any? { |c| c.start_with?("5671") || c == "5671-3" }, "Expected blood lead level"
end

# Then: ORU message segments

Then("the ORU message should contain the MSH segment") do
  assert @oru_message.include?("MSH|"), "Expected MSH segment"
end

Then("the ORU message should contain the PID segment") do
  assert @oru_message.include?("PID|"), "Expected PID segment"
end

Then("the ORU message should contain the OBR segment") do
  assert @oru_message.include?("OBR|"), "Expected OBR segment"
end

Then("the ORU message should contain the OBX segment") do
  assert @oru_message.include?("OBX|"), "Expected OBX segment"
end

Then("the ORU message should contain the SPM segment") do
  assert @oru_message.include?("SPM|"), "Expected SPM segment"
end

Then("the OBX segment should include the LOINC code") do
  obx_line = @oru_message.split("\r").reject(&:blank?).find { |l| l.start_with?("OBX|") }
  assert obx_line.present?, "Expected OBX segment"
  assert obx_line.include?(@lab_observation.code), "Expected LOINC code #{@lab_observation.code} in OBX"
end

Then("the OBX segment should include the SNOMED organism code") do
  obx_lines = @oru_message.split("\r").reject(&:blank?).select { |l| l.start_with?("OBX|") }
  organism_obx = obx_lines.find { |l| l.include?(@organism[:code]) }
  assert organism_obx.present?, "Expected SNOMED organism code #{@organism[:code]} in OBX"
end

# Then: ECLRS transmission (unique step names to avoid conflict with e-prescribing)

Then("the ELR transmission should succeed") do
  assert @elr_result[:success], "Expected ELR transmission to succeed: #{@elr_result[:errors]}"
end

Then("the ELR transmission should include a tracking ID") do
  assert @elr_result[:tracking_id].present?, "Expected ELR tracking ID"
end

Then("an audit event should be recorded for the lab submission") do
  event = Lakeraven::EHR::AuditEvent.last
  assert event.present?, "Expected audit event"
  assert_match(/elr|lab.report/i, event.outcome_desc)
end
