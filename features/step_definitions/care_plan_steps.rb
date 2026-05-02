# frozen_string_literal: true

# CarePlan step definitions

Given("a care plan with title {string} for patient {string}") do |title, dfn|
  @care_plan = Lakeraven::EHR::CarePlan.new(patient_dfn: dfn, title: title)
end

Given("a care plan without a patient") do
  @care_plan = Lakeraven::EHR::CarePlan.new(title: "Test Plan")
end

Given("a care plan with title {string} and category {string} for patient {string}") do |title, cat, dfn|
  @care_plan = Lakeraven::EHR::CarePlan.new(patient_dfn: dfn, title: title, category: cat)
end

When("I serialize the care plan to FHIR") do
  @fhir = @care_plan.to_fhir
end

Then("the care plan should be valid") do
  assert @care_plan.valid?, "Expected valid: #{@care_plan.errors.full_messages}"
end

Then("the care plan should be invalid") do
  refute @care_plan.valid?
end

Then("the care plan should be active") do
  assert @care_plan.active?, "Expected active"
end

Then("the FHIR care plan status should be {string}") do |expected|
  assert_equal expected, @fhir[:status]
end

Then("the FHIR care plan intent should be {string}") do |expected|
  assert_equal expected, @fhir[:intent]
end

Then("the FHIR care plan title should be {string}") do |expected|
  assert_equal expected, @fhir[:title]
end
