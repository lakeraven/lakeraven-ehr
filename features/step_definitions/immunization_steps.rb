# frozen_string_literal: true

# Immunization step definitions

Given("an immunization with vaccine {string} for patient {string}") do |vaccine, dfn|
  @immunization = Lakeraven::EHR::Immunization.new(
    patient_dfn: dfn, vaccine_display: vaccine, status: "completed"
  )
end

Given("an immunization without a patient") do
  @immunization = Lakeraven::EHR::Immunization.new(
    vaccine_display: "Test Vaccine", status: "completed"
  )
end

Given("an immunization without a vaccine for patient {string}") do |dfn|
  @immunization = Lakeraven::EHR::Immunization.new(
    patient_dfn: dfn, status: "completed"
  )
end

Given("a completed immunization with vaccine {string} for patient {string}") do |vaccine, dfn|
  @immunization = Lakeraven::EHR::Immunization.new(
    patient_dfn: dfn, vaccine_display: vaccine, status: "completed"
  )
end

Given("an immunization with vaccine {string} and CVX {string} for patient {string}") do |vaccine, cvx, dfn|
  @immunization = Lakeraven::EHR::Immunization.new(
    patient_dfn: dfn, vaccine_display: vaccine, vaccine_code: cvx, status: "completed"
  )
end

Given("an immunization with vaccine {string} and VFC {string} for patient {string}") do |vaccine, vfc, dfn|
  @immunization = Lakeraven::EHR::Immunization.new(
    patient_dfn: dfn, vaccine_display: vaccine, vfc_eligibility_code: vfc, status: "completed"
  )
end

When("I serialize the immunization to FHIR") do
  @fhir = @immunization.to_fhir
end

Then("the immunization should be valid") do
  assert @immunization.valid?, "Expected valid: #{@immunization.errors.full_messages}"
end

Then("the immunization should be invalid") do
  refute @immunization.valid?
end

Then("the immunization should be completed") do
  assert @immunization.completed?, "Expected completed"
end

Then("the FHIR immunization patient reference should include {string}") do |dfn|
  patient = @fhir[:patient]
  refute_nil patient
  assert_includes patient[:reference], dfn
end

Then("the FHIR vaccine code should include {string}") do |cvx|
  vc = @fhir[:vaccineCode]
  refute_nil vc
  assert vc[:coding]&.any? { |c| c[:code] == cvx },
    "Expected CVX #{cvx} in vaccine code"
end
