# frozen_string_literal: true

# Terminology mapper step definitions

Given("an ICD-10 code {string} with edition {string}") do |code, edition|
  @terminology = Lakeraven::EHR::Terminology::ICD10.new(code, edition: edition.to_sym)
end

Given("an ICD-10 code {string} with no edition") do |code|
  @terminology = Lakeraven::EHR::Terminology::ICD10.new(code, edition: nil)
end

Given("a LOINC code {string}") do |code|
  @terminology = Lakeraven::EHR::Terminology::LOINC.new(code)
end

Given("an RxNorm code {string}") do |code|
  @terminology = Lakeraven::EHR::Terminology::RxNorm.new(code)
end

Given("an ATC code {string}") do |code|
  @terminology = Lakeraven::EHR::Terminology::ATC.new(code)
end

Given("a DIN code {string}") do |code|
  @terminology = Lakeraven::EHR::Terminology::DIN.new(code)
end

Given("a SNOMED code {string} with no edition") do |code|
  @terminology = Lakeraven::EHR::Terminology::SNOMED.new(code)
end

Given("a SNOMED code {string} with edition {string}") do |code, edition|
  @terminology = Lakeraven::EHR::Terminology::SNOMED.new(code, edition: edition.to_sym)
end

When("I convert to FHIR Coding") do
  @coding = @terminology.to_coding
end

Then("the terminology system should be {string}") do |expected|
  assert_equal expected, @terminology.system
end

Then("the terminology code should be {string}") do |expected|
  assert_equal expected, @terminology.code
end

Then("the terminology status should be {string}") do |expected|
  assert_equal expected.to_sym, @terminology.status
end

Then("the coding system should be {string}") do |expected|
  assert_equal expected, @coding[:system]
end

Then("the coding code should be {string}") do |expected|
  assert_equal expected, @coding[:code]
end

Then("the coding version should be {string}") do |expected|
  assert_equal expected, @coding[:version]
end

Then("the coding should not have a version") do
  refute @coding.key?(:version), "Expected no version in coding"
end
