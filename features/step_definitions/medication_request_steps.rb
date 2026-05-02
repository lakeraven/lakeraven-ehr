# frozen_string_literal: true

# MedicationRequest step definitions

Given("a medication request for {string} for patient {string}") do |med, dfn|
  @medication_request = Lakeraven::EHR::MedicationRequest.new(
    patient_dfn: dfn, medication_display: med
  )
end

Given("a medication request without a patient") do
  @medication_request = Lakeraven::EHR::MedicationRequest.new(
    medication_display: "Test Med"
  )
end

Given("a medication request without a medication for patient {string}") do |dfn|
  @medication_request = Lakeraven::EHR::MedicationRequest.new(patient_dfn: dfn)
end

Given("a medication request for {string} with status {string} for patient {string}") do |med, status, dfn|
  @medication_request = Lakeraven::EHR::MedicationRequest.new(
    patient_dfn: dfn, medication_display: med, status: status
  )
end

Given("a medication request for {string} with RxNorm {string} for patient {string}") do |med, code, dfn|
  @medication_request = Lakeraven::EHR::MedicationRequest.new(
    patient_dfn: dfn, medication_display: med, medication_code: code
  )
end

When("I serialize the medication request to FHIR") do
  @fhir = @medication_request.to_fhir
end

Then("the medication request should be valid") do
  assert @medication_request.valid?, "Expected valid: #{@medication_request.errors.full_messages}"
end

Then("the medication request should be invalid") do
  refute @medication_request.valid?
end

Then("the medication request should be active") do
  assert @medication_request.active?, "Expected active"
end

Then("the medication matching key should be {string}") do |expected|
  assert_equal expected, @medication_request.matching_key
end

Then("the medication request should have a signed content hash") do
  hash = @medication_request.signed_content_hash
  refute_nil hash
  assert_equal 64, hash.length, "Expected SHA-256 hex string"
end

Then("the FHIR medication code should include {string}") do |code|
  med = @fhir[:medicationCodeableConcept]
  refute_nil med
  assert med[:coding]&.any? { |c| c[:code] == code },
    "Expected code #{code} in medication coding"
end
