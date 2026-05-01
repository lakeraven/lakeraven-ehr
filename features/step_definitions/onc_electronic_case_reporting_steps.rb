# frozen_string_literal: true

# ONC § 170.315(f)(5) — Electronic Case Reporting step definitions
# Covers reportable condition triggers, eICR generation, RR processing, ECLRS transmission.
#
# Shared steps NOT redefined here:
#   "a patient exists with DFN {string}" — cpoe_steps.rb
#   "the generation should complete in under {int} seconds" — electronic_prescribing_steps.rb

# -----------------------------------------------------------------------------
# Given: patient conditions and clinical data
# -----------------------------------------------------------------------------

Given("the patient has a confirmed diagnosis of {string} for {string}") do |code, display|
  @condition = Lakeraven::EHR::Condition.new(
    ien: "cond-#{SecureRandom.hex(4)}",
    patient_dfn: @patient_dfn || "12345",
    code: code,
    code_system: "icd10",
    display: display,
    clinical_status: "active",
    verification_status: "confirmed",
    category: "encounter-diagnosis",
    onset_datetime: Time.current
  )
end

Given("the patient has clinical data for the case report") do
  @case_report_data = {
    patient: {
      dfn: @patient_dfn || "12345",
      name: { given: "Alice", family: "Anderson" },
      dob: "1975-06-15", sex: "F",
      address: { street: "123 Main St", city: "Kingston", state: "NY", zip: "12401" }
    },
    encounter: {
      date: Time.current.strftime("%Y-%m-%d"),
      type_code: "99213",
      type_display: "Office visit",
      facility: "Ulster County Health Department"
    },
    provider: {
      duz: "789", name: "Dr. Smith", npi: "1234567890"
    }
  }
end

Given("an eICR was submitted for the patient") do
  @submitted_eicr_id = "eicr-#{SecureRandom.hex(8)}"
end

Given("an eICR document has been generated") do
  @eicr_xml = Lakeraven::EHR::EicrGenerator.generate(
    condition: @condition,
    patient: @case_report_data[:patient],
    encounter: @case_report_data[:encounter],
    provider: @case_report_data[:provider]
  )
end

# -----------------------------------------------------------------------------
# When: trigger evaluation and eICR generation
# -----------------------------------------------------------------------------

When("the condition is evaluated for reportability") do
  @reportability = Lakeraven::EHR::ReportableConditionService.evaluate(@condition)
end

When("the reportable conditions list is loaded") do
  @conditions_list = Lakeraven::EHR::ReportableConditionService.all_conditions
end

When("an eICR document is generated") do
  @eicr_xml = Lakeraven::EHR::EicrGenerator.generate(
    condition: @condition,
    patient: @case_report_data[:patient],
    encounter: @case_report_data[:encounter],
    provider: @case_report_data[:provider]
  )
  @eicr_doc = Nokogiri::XML(@eicr_xml)
end

When("an eICR document is generated with timing") do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @eicr_xml = Lakeraven::EHR::EicrGenerator.generate(
    condition: @condition,
    patient: @case_report_data[:patient],
    encounter: @case_report_data[:encounter],
    provider: @case_report_data[:provider]
  )
  @generation_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

When("a reportability response is received indicating {string}") do |determination|
  @rr_result = Lakeraven::EHR::ReportabilityResponseProcessor.process(
    eicr_id: @submitted_eicr_id,
    patient_dfn: @patient_dfn || "12345",
    determination: determination,
    jurisdiction: "NY"
  )
end

When("the eICR is transmitted to ECLRS") do
  adapter = Lakeraven::EHR::Ecr::MockEclrsAdapter.new
  @eclrs_service = Lakeraven::EHR::Ecr::EclrsTransmissionService.new(adapter: adapter)
  @eclrs_result = @eclrs_service.submit(
    eicr_xml: @eicr_xml,
    patient_dfn: @patient_dfn || "12345",
    provider_duz: "789"
  )
end

# -----------------------------------------------------------------------------
# Then: trigger results
# -----------------------------------------------------------------------------

Then("the condition should be flagged as reportable") do
  assert @reportability[:reportable], "Expected condition to be reportable"
end

Then("the condition should not be flagged as reportable") do
  refute @reportability[:reportable], "Expected condition to NOT be reportable"
end

Then("the trigger should reference the reportable conditions list") do
  assert @reportability[:trigger_source].present?, "Expected trigger source reference"
end

Then("the list should include tuberculosis") do
  codes = @conditions_list.map { |c| c[:code] }
  assert codes.include?("A15.0") || codes.include?("A15"), "Expected TB in reportable list"
end

Then("the list should include hepatitis B") do
  codes = @conditions_list.map { |c| c[:code] }
  assert codes.any? { |c| c.start_with?("B16") || c.start_with?("B18.1") }, "Expected Hep B in reportable list"
end

Then("the list should include gonorrhea") do
  codes = @conditions_list.map { |c| c[:code] }
  assert codes.any? { |c| c.start_with?("A54") }, "Expected gonorrhea in reportable list"
end

Then("the list should include chlamydia") do
  codes = @conditions_list.map { |c| c[:code] }
  assert codes.any? { |c| c.start_with?("A56") }, "Expected chlamydia in reportable list"
end

Then("the list should include HIV") do
  codes = @conditions_list.map { |c| c[:code] }
  assert codes.any? { |c| c.start_with?("B20") }, "Expected HIV in reportable list"
end

# Then: eICR document

Then("the eICR should be valid XML") do
  doc = Nokogiri::XML(@eicr_xml) { |config| config.strict }
  assert doc.errors.empty?, "Expected valid XML, got errors: #{doc.errors.map(&:message)}"
end

Then("the eICR should have the eICR template ID") do
  templates = @eicr_doc.xpath("//xmlns:templateId/@root", "xmlns" => "urn:hl7-org:v3").map(&:value)
  assert templates.include?("2.16.840.1.113883.10.20.15.2"), "Expected eICR template ID"
end

Then("the eICR should include patient demographics") do
  patient = @eicr_doc.at_xpath("//xmlns:patient", "xmlns" => "urn:hl7-org:v3")
  assert patient.present?, "Expected patient demographics in eICR"
end

Then("the eICR should include the reportable condition") do
  condition = @eicr_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.15.2.3.2']]",
    "xmlns" => "urn:hl7-org:v3"
  ) || @eicr_doc.at_xpath("//xmlns:value[@code]", "xmlns" => "urn:hl7-org:v3")
  assert condition.present?, "Expected reportable condition in eICR"
end

Then("the eICR should include the responsible provider") do
  author = @eicr_doc.at_xpath("//xmlns:author", "xmlns" => "urn:hl7-org:v3")
  assert author.present?, "Expected author/provider in eICR"
end

Then("the eICR should include the triggering encounter") do
  encounter = @eicr_doc.at_xpath(
    "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]",
    "xmlns" => "urn:hl7-org:v3"
  ) || @eicr_doc.at_xpath("//xmlns:encompassingEncounter", "xmlns" => "urn:hl7-org:v3")
  assert encounter.present?, "Expected encounter in eICR"
end

# Then: reportability response

Then("the response status should be recorded") do
  assert @rr_result[:success], "Expected successful RR processing"
  assert @rr_result[:determination].present?
end

Then("the response should reference the original eICR") do
  assert_equal @submitted_eicr_id, @rr_result[:eicr_id]
end

Then("the response status should be recorded as not reportable") do
  assert @rr_result[:success]
  assert_equal "not reportable", @rr_result[:determination]
end

# Then: ECLRS transmission (unique step names to avoid conflict with e-prescribing)

Then("the ECR transmission should succeed") do
  assert @eclrs_result[:success], "Expected ECLRS transmission to succeed: #{@eclrs_result[:errors]}"
end

Then("the ECR transmission should include a tracking ID") do
  assert @eclrs_result[:tracking_id].present?, "Expected ECLRS tracking ID"
end

Then("an audit event should be recorded for the submission") do
  event = Lakeraven::EHR::AuditEvent.last
  assert event.present?, "Expected audit event"
  assert_match(/ecr|eicr|case.report/i, event.outcome_desc)
end
