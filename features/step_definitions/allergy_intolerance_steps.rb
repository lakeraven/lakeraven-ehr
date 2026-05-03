# frozen_string_literal: true

# AllergyIntolerance step definitions

Given("an allergy to {string} for patient {string}") do |allergen, dfn|
  @allergy = Lakeraven::EHR::AllergyIntolerance.new(
    patient_dfn: dfn, allergen: allergen, clinical_status: "active"
  )
end

Given("a medication allergy to {string} for patient {string}") do |allergen, dfn|
  @allergy = Lakeraven::EHR::AllergyIntolerance.new(
    patient_dfn: dfn, allergen: allergen, clinical_status: "active", category: "medication"
  )
end

Given("a food allergy to {string} for patient {string}") do |allergen, dfn|
  @allergy = Lakeraven::EHR::AllergyIntolerance.new(
    patient_dfn: dfn, allergen: allergen, clinical_status: "active", category: "food"
  )
end

Given("an allergy to {string} with code {string} for patient {string}") do |allergen, code, dfn|
  @allergy = Lakeraven::EHR::AllergyIntolerance.new(
    patient_dfn: dfn, allergen: allergen, allergen_code: code, clinical_status: "active"
  )
end

When("I serialize the allergy to FHIR") do
  @fhir = @allergy.to_fhir
end

Then("the allergy should be active") do
  assert @allergy.active?, "Expected active"
end

Then("the allergy should be a medication allergy") do
  assert @allergy.medication?, "Expected medication allergy"
end

Then("the allergy should be a food allergy") do
  assert @allergy.food?, "Expected food allergy"
end

Then("the allergy matching key should be {string}") do |expected|
  assert_equal expected, @allergy.matching_key
end

Then("the FHIR allergy patient reference should include {string}") do |dfn|
  patient = @fhir[:patient]
  refute_nil patient
  assert_includes patient[:reference], dfn
end

Then("the FHIR allergy code text should be {string}") do |expected|
  assert_equal expected, @fhir[:code][:text]
end
