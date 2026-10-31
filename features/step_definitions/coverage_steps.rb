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

Given("a Medicaid enrollment eligibility response for patient {string}") do |dfn|
  @eligibility_response = Lakeraven::EHR::CoverageEligibilityResponse.new(
    patient_dfn: dfn,
    coverage_type: "medicaid",
    status: "enrolled",
    plan_name: "State Medicaid",
    insurer_name: "State Medicaid Agency",
    start_date: Date.new(2024, 1, 1),
    end_date: Date.new(2024, 12, 31)
  )
end

When("I build coverage from the eligibility response") do
  @coverage = Lakeraven::EHR::Coverage.from_eligibility_response(@eligibility_response)
end

Then("the coverage payor should be {string}") do |payor|
  assert_equal payor, @coverage.payor_display
end

Then("the coverage type should be {string}") do |type|
  assert_equal type, @coverage.coverage_type
end

Given("the coverage payor name is {string}") do |payor_name|
  @coverage.payor_name = payor_name
end

Given("the coverage plan name is {string}") do |plan_name|
  @coverage.plan_name = plan_name
end

Given("the coverage member id is {string}") do |member_id|
  @coverage.member_id = member_id
end

Given("the coverage period starts on {string}") do |start_date|
  @coverage.start_date = Date.parse(start_date)
end

Then("the FHIR Coverage subscriber id should be {string}") do |subscriber_id|
  assert_equal subscriber_id, @fhir[:subscriberId]
end

Then("the FHIR Coverage subscriber id should be absent") do
  assert @fhir[:subscriberId].blank?, "Expected no FHIR Coverage.subscriberId"
end

Then("the FHIR Coverage plan class value should be {string}") do |value|
  plan_class = @fhir[:class]&.find { |c| c.dig(:type, :coding, 0, :code) == "plan" }
  assert plan_class, "Expected class[type=plan]"
  assert_equal value, plan_class[:value]
end

Then("the FHIR Coverage plan class name should be {string}") do |name|
  plan_class = @fhir[:class]&.find { |c| c.dig(:type, :coding, 0, :code) == "plan" }
  assert plan_class, "Expected class[type=plan]"
  assert_equal name, plan_class[:name]
end

Given("the coverage group id is {string}") do |group_id|
  @coverage.group_id = group_id
end

Given("the coverage subscriber id is {string}") do |subscriber_id|
  @coverage.subscriber_id = subscriber_id
end

Then("each FHIR Coverage class type coding system should be {string}") do |system|
  assert @fhir[:class].present?, "Expected Coverage.class"
  @fhir[:class].each do |cls|
    coding_system = cls.dig(:type, :coding, 0, :system)
    assert_equal system, coding_system
  end
end

Then("the FHIR Coverage member identifier type system should be {string}") do |system|
  mb = member_identifier_entry
  assert mb, "Expected identifier with type MB"
  assert_equal system, mb.dig(:type, :coding, 0, :system)
end

Then("the FHIR Coverage member identifier type code should be {string}") do |code|
  mb = member_identifier_entry
  assert mb, "Expected identifier with type MB"
  assert_equal code, mb.dig(:type, :coding, 0, :code)
end

Then("the FHIR Coverage member identifier value should be {string}") do |value|
  mb = member_identifier_entry
  assert mb, "Expected identifier with type MB"
  assert_equal value, mb[:value]
end

Then("the coverage model status should be {string}") do |status|
  assert_equal status, @coverage.status
end

Then("the FHIR Coverage type coding system should be {string}") do |system|
  coding = @fhir.dig(:type, :coding, 0)
  assert coding, "Expected Coverage.type coding"
  assert_equal system, coding[:system]
end

Then("the FHIR Coverage type coding code should be {string}") do |code|
  coding = @fhir.dig(:type, :coding, 0)
  assert coding, "Expected Coverage.type coding"
  assert_equal code, coding[:code]
end

Then("the FHIR Coverage type coding display should be present") do
  display = @fhir.dig(:type, :coding, 0, :display)
  assert display.present?, "Expected display on Coverage.type coding"
end

PRC_STATUS_EXTENSION_URL = "urn:lakeraven:fhir:StructureDefinition/prc-coverage-status"

Then("the FHIR Coverage PRC status extension should be {string}") do |prc_status|
  extension = Array(@fhir[:extension]).find { |ext| ext[:url] == PRC_STATUS_EXTENSION_URL }
  assert extension, "Expected PRC status extension on Coverage"
  assert_equal prc_status, extension[:valueCode]
end

def member_identifier_entry
  @fhir[:identifier]&.find do |id|
    coding = id.dig(:type, :coding, 0)
    coding&.dig(:code) == "MB"
  end
end

# "the FHIR period start/end should be" defined in encounter_model_steps.rb
