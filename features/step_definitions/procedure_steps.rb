# frozen_string_literal: true

# Procedure step definitions

Given("a procedure with display {string} for patient {string}") do |display, dfn|
  @procedure = Lakeraven::EHR::Procedure.new(patient_dfn: dfn, display: display, status: "completed")
end

Given("a procedure without a patient") do
  @procedure = Lakeraven::EHR::Procedure.new(display: "Test", status: "completed")
end

Given("a procedure without a display for patient {string}") do |dfn|
  @procedure = Lakeraven::EHR::Procedure.new(patient_dfn: dfn, status: "completed")
end

Given("a procedure with display {string} and code {string} system {string} for patient {string}") do |display, code, system, dfn|
  @procedure = Lakeraven::EHR::Procedure.new(
    patient_dfn: dfn, display: display, code: code, code_system: system, status: "completed"
  )
end

Given("a completed procedure with display {string} for patient {string}") do |display, dfn|
  @procedure = Lakeraven::EHR::Procedure.new(
    patient_dfn: dfn, display: display, status: "completed"
  )
end

Given("a procedure with display {string} and performer {string} for patient {string}") do |display, duz, dfn|
  @procedure = Lakeraven::EHR::Procedure.new(
    patient_dfn: dfn, display: display, status: "completed",
    performer_duz: duz, performer_name: "Dr. Test"
  )
end

When("I serialize the procedure to FHIR") do
  @fhir = @procedure.to_fhir
end

Then("the procedure should be valid") do
  assert @procedure.valid?, "Expected valid: #{@procedure.errors.full_messages}"
end

Then("the procedure should be invalid") do
  refute @procedure.valid?
end

Then("the procedure should be completed") do
  assert @procedure.completed?, "Expected completed"
end

Then("the FHIR procedure code should include {string}") do |code|
  fhir_code = @fhir[:code]
  refute_nil fhir_code
  assert fhir_code[:coding]&.any? { |c| c[:code] == code },
    "Expected code #{code} in coding"
end

Then("the FHIR procedure performer should include {string}") do |duz|
  performers = @fhir[:performer]
  refute_nil performers
  assert performers.any? { |p| p[:actor][:reference]&.include?(duz) },
    "Expected performer #{duz}"
end
