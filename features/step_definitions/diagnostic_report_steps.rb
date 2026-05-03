# frozen_string_literal: true

# DiagnosticReport step definitions

Given("a diagnostic report with code {string} for patient {string}") do |code_display, dfn|
  @diagnostic_report = Lakeraven::EHR::DiagnosticReport.new(
    patient_dfn: dfn, code_display: code_display
  )
end

Given("a diagnostic report without a patient") do
  @diagnostic_report = Lakeraven::EHR::DiagnosticReport.new(code_display: "CBC")
end

Given("a diagnostic report without a code for patient {string}") do |dfn|
  @diagnostic_report = Lakeraven::EHR::DiagnosticReport.new(patient_dfn: dfn)
end

Given("a lab diagnostic report with code {string} and LOINC {string} for patient {string}") do |display, loinc, dfn|
  @diagnostic_report = Lakeraven::EHR::DiagnosticReport.new(
    patient_dfn: dfn, code_display: display, code: loinc, category: "LAB"
  )
end

Given("a radiology diagnostic report with code {string} for patient {string}") do |display, dfn|
  @diagnostic_report = Lakeraven::EHR::DiagnosticReport.new(
    patient_dfn: dfn, code_display: display, category: "RAD"
  )
end

When("I serialize the diagnostic report to FHIR") do
  @fhir = @diagnostic_report.to_fhir
end

Then("the diagnostic report should be valid") do
  assert @diagnostic_report.valid?, "Expected valid: #{@diagnostic_report.errors.full_messages}"
end

Then("the diagnostic report should be invalid") do
  refute @diagnostic_report.valid?
end

Then("the FHIR diagnostic report status should be {string}") do |expected|
  assert_equal expected, @fhir[:status]
end

Then("the FHIR diagnostic report category should be {string}") do |expected|
  cats = @fhir[:category]
  refute_nil cats
  assert cats.any? { |c| c[:coding]&.any? { |cd| cd[:code] == expected } },
    "Expected category #{expected}"
end
