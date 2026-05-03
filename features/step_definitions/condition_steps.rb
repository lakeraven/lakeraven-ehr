# frozen_string_literal: true

# Condition step definitions

Given("a condition with display {string} for patient {string}") do |display, dfn|
  @condition = Lakeraven::EHR::Condition.new(patient_dfn: dfn, display: display)
end

Given("a condition without a patient") do
  @condition = Lakeraven::EHR::Condition.new(display: "Test")
end

Given("a condition without a display for patient {string}") do |dfn|
  @condition = Lakeraven::EHR::Condition.new(patient_dfn: dfn)
end

Given("a condition with display {string} and status {string} for patient {string}") do |display, status, dfn|
  @condition = Lakeraven::EHR::Condition.new(
    patient_dfn: dfn, display: display, clinical_status: status
  )
end

Given("a condition with display {string} and category {string} for patient {string}") do |display, cat, dfn|
  @condition = Lakeraven::EHR::Condition.new(
    patient_dfn: dfn, display: display, category: cat
  )
end

Given("a condition with display {string} and ICD code {string} for patient {string}") do |display, code, dfn|
  @condition = Lakeraven::EHR::Condition.new(
    patient_dfn: dfn, display: display, code: code, code_system: "icd10"
  )
end

When("I serialize the condition to FHIR") do
  @fhir = @condition.to_fhir
end

Then("the condition should be valid") do
  assert @condition.valid?, "Expected valid: #{@condition.errors.full_messages}"
end

Then("the condition should be invalid") do
  refute @condition.valid?
end

Then("the condition should be active") do
  assert @condition.active?, "Expected active"
end

Then("the condition should be resolved") do
  assert @condition.resolved?, "Expected resolved"
end

Then("the condition should be a problem list item") do
  assert @condition.problem_list_item?, "Expected problem list item"
end

Then("the condition matching key should be {string}") do |expected|
  assert_equal expected, @condition.matching_key
end

Then("the FHIR condition code should include {string}") do |code|
  fhir_code = @fhir[:code]
  refute_nil fhir_code
  assert fhir_code[:coding]&.any? { |c| c[:code] == code },
    "Expected code #{code} in coding"
end
