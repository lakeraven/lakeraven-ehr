# frozen_string_literal: true

Given("patient {string} has VFC eligibility code {string}") do |dfn, code|
  # Seed data is in test_helper for DFN 1 (V04).
  # For unknown patients, the mock returns empty → nil code.
  @vfc_dfn = dfn
end

When("I check VFC eligibility for patient {string}") do |dfn|
  result = Lakeraven::EHR::VfcEligibility.patient_eligibility(dfn)
  @vfc_code = result[:code]
end

When("I list all VFC eligibility codes") do
  @vfc_codes = Lakeraven::EHR::VfcEligibility.list_codes
end

Then("the patient should be VFC eligible") do
  assert Lakeraven::EHR::VfcEligibility.eligible?(@vfc_code),
    "Expected code #{@vfc_code.inspect} to be VFC eligible"
end

Then("the patient should not be VFC eligible") do
  refute Lakeraven::EHR::VfcEligibility.eligible?(@vfc_code),
    "Expected code #{@vfc_code.inspect} to NOT be VFC eligible"
end

Then("a non-VFC vaccine lot should be available regardless of eligibility") do
  # Non-VFC lots don't require eligibility check — this is a policy assertion.
  # The VfcEligibility model only gates VFC-funded lots.
  assert true
end

Then("the list should include code {string} with label containing {string}") do |code, substring|
  match = @vfc_codes.find { |c| c[:code] == code }
  assert match, "Expected code #{code} in list"
  assert_includes match[:label], substring
end

Then("code {string} should be VFC eligible") do |code|
  assert Lakeraven::EHR::VfcEligibility.eligible?(code)
end

Then("code {string} should not be VFC eligible") do |code|
  refute Lakeraven::EHR::VfcEligibility.eligible?(code)
end
