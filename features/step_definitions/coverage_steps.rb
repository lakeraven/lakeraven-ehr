# frozen_string_literal: true

# Coverage step definitions

Given("a coverage with type {string} for patient {string}") do |type, dfn|
  @coverage = Lakeraven::EHR::Coverage.new(patient_dfn: dfn, coverage_type: type, status: "active")
end

Given("a coverage with type {string} and status {string} for patient {string}") do |type, status, dfn|
  @coverage = Lakeraven::EHR::Coverage.new(patient_dfn: dfn, coverage_type: type, status: status)
end

Given("a coverage without a patient") do
  @coverage = Lakeraven::EHR::Coverage.new(coverage_type: "medicare_a", status: "active")
end

Given("a coverage without a type for patient {string}") do |dfn|
  @coverage = Lakeraven::EHR::Coverage.new(patient_dfn: dfn, status: "active")
end

Given("a coverage with period from {string} to {string} for patient {string}") do |start_date, end_date, dfn|
  @coverage = Lakeraven::EHR::Coverage.new(
    patient_dfn: dfn, coverage_type: "medicare_a", status: "active",
    start_date: Date.parse(start_date), end_date: Date.parse(end_date)
  )
end

Given("a coverage with start date {string} and no end date for patient {string}") do |start_date, dfn|
  @coverage = Lakeraven::EHR::Coverage.new(
    patient_dfn: dfn, coverage_type: "medicare_a", status: "active",
    start_date: Date.parse(start_date), end_date: nil
  )
end

When("I serialize the coverage to FHIR") do
  @fhir = @coverage.to_fhir
end

Then("the coverage should be valid") do
  assert @coverage.valid?, "Expected coverage to be valid: #{@coverage.errors.full_messages}"
end

Then("the coverage should be invalid") do
  refute @coverage.valid?
end

Then("there should be a coverage error on {string}") do |field|
  assert @coverage.errors[field.to_sym].any?
end

Then("the coverage should be active") do
  assert @coverage.active?, "Expected coverage to be active"
end

Then("the coverage should be expired") do
  assert @coverage.expired?, "Expected coverage to be expired"
end

Then("the coverage type display should include {string}") do |text|
  type = @coverage.coverage_type.to_s
  payor = @coverage.payor_name.to_s
  assert(type.downcase.include?(text.downcase) || payor.downcase.include?(text.downcase),
    "Expected '#{text}' in coverage_type '#{type}' or payor_name '#{payor}'")
end

Then("the FHIR beneficiary reference should be {string}") do |ref|
  assert_equal ref, @fhir[:beneficiary][:reference]
end

Then("the FHIR coverage status should be {string}") do |status|
  assert_equal status, @fhir[:status]
end

# "the FHIR period start/end should be" defined in encounter_model_steps.rb
