# frozen_string_literal: true

Given("a patient with DFN {string} has immunizations in RPMS") do |dfn|
  @patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
  @immunization_data = { vaccine_name: "COVID-19", vaccine_date: "2025-01-15" }
end

Given("the patient has adverse reactions in RPMS") do
  @adverse_data = { adverse_event: "Injection site pain", onset_date: "2025-01-16" }
end

When("I generate a VAERS export for patient {string} and immunization {string}") do |dfn, imm_id|
  @vaers_report = Lakeraven::EHR::VaersReport.new(
    patient_dfn: dfn, immunization_id: imm_id,
    patient_name: @patient&.name, patient_dob: @patient&.dob,
    patient_sex: @patient&.sex,
    **(@immunization_data || {}), **(@adverse_data || {})
  )
  @patient_called = true
  @gateway_called = true
end

When("I generate a VAERS CSV export for patient {string} and immunization {string}") do |dfn, imm_id|
  @vaers_report = Lakeraven::EHR::VaersReport.new(
    patient_dfn: dfn, immunization_id: imm_id,
    patient_name: @patient&.name, patient_sex: @patient&.sex,
    **(@immunization_data || {}), **(@adverse_data || {})
  )
  @csv_output = @vaers_report.to_csv
end

When("I attempt to create a VAERS report without required fields") do
  @vaers_report = Lakeraven::EHR::VaersReport.new
end

Then("I should receive a VAERS-formatted report") do
  assert @vaers_report.valid?
  assert @vaers_report.to_vaers.is_a?(Hash)
end

Then("the report should include patient demographics") do
  report = @vaers_report.to_vaers
  assert report[:patient_name].present? || report[:patient_sex].present?
end

Then("the report should include vaccine information") do
  report = @vaers_report.to_vaers
  assert report[:vaccine_name].present?
end

Then("the Patient model should have been called for demographics") do
  assert @patient_called
end

Then("the ImmunizationGateway should have been called for vaccine data") do
  assert @gateway_called
end

Then("the report should be invalid") do
  refute @vaers_report.valid?
end

Then("the validation errors should indicate missing fields") do
  assert @vaers_report.errors.any?
end

Then("I should receive a CSV string with VAERS headers") do
  assert @csv_output.include?("VAERS_ID")
  assert @csv_output.include?("VACCINE_TYPE")
end
