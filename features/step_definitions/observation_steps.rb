# frozen_string_literal: true

# Observation step definitions

Given("a vital sign observation with code {string} and value {string} for patient {string}") do |code, value, dfn|
  @observation = Lakeraven::EHR::Observation.new(
    patient_dfn: dfn, code: code, code_system: "loinc", value: value,
    value_quantity: value, category: "vital-signs", status: "final"
  )
end

Given("a laboratory observation with code {string} and value {string} for patient {string}") do |code, value, dfn|
  @observation = Lakeraven::EHR::Observation.new(
    patient_dfn: dfn, code: code, value: value, value_quantity: value,
    category: "laboratory", status: "final"
  )
end

Given("an SDOH observation with code {string} and value {string} for patient {string}") do |code, value, dfn|
  @observation = Lakeraven::EHR::Observation.new(
    patient_dfn: dfn, code: code, code_system: "loinc", value: value,
    category: "social-history", status: "final"
  )
end

Given("a blood pressure observation with value {string} for patient {string}") do |value, dfn|
  @observation = Lakeraven::EHR::Observation.new(
    patient_dfn: dfn, code: "85354-9", code_system: "loinc", value: value,
    category: "vital-signs", status: "final"
  )
end

Given("vital sign hashes for patient {string} with type {string} value {string} and type {string} value {string}") do |dfn, t1, v1, t2, v2|
  hashes = [
    { type: t1, value: v1 },
    { type: t2, value: v2 }
  ]
  @observations = Lakeraven::EHR::Observation.from_vital_hashes(hashes, patient_dfn: dfn)
end

When("I serialize the observation to FHIR") do
  @fhir = @observation.to_fhir
end

Then("the observation should be a vital sign") do
  assert @observation.vital_sign?, "Expected vital sign"
end

Then("the observation should be a laboratory result") do
  assert @observation.laboratory?, "Expected laboratory"
end

Then("the observation should be an SDOH observation") do
  assert @observation.sdoh?, "Expected SDOH"
end

Then("the FHIR observation should have systolic and diastolic components") do
  components = @fhir[:component]
  refute_nil components
  assert_equal 2, components.length, "Expected 2 components (systolic + diastolic)"
end

Then("the FHIR observation category should be {string}") do |expected|
  cats = @fhir[:category]
  refute_nil cats
  assert cats.any? { |c| c[:coding]&.any? { |cd| cd[:code] == expected } },
    "Expected category #{expected}"
end

Then("there should be {int} observations") do |count|
  assert_equal count, @observations.length
end

Then("the first observation code should be {string}") do |code|
  assert_equal code, @observations.first.code
end
