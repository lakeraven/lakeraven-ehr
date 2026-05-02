# frozen_string_literal: true

# Goal step definitions

Given("a goal with description {string} for patient {string}") do |desc, dfn|
  @goal = Lakeraven::EHR::Goal.new(patient_dfn: dfn, description: desc)
end

Given("a goal without a patient") do
  @goal = Lakeraven::EHR::Goal.new(description: "Test Goal")
end

Given("a goal without a description for patient {string}") do |dfn|
  @goal = Lakeraven::EHR::Goal.new(patient_dfn: dfn)
end

Given("a goal with description {string} and achievement {string} for patient {string}") do |desc, achievement, dfn|
  @goal = Lakeraven::EHR::Goal.new(
    patient_dfn: dfn, description: desc, achievement_status: achievement
  )
end

Given("a goal with description {string} and target {string} for patient {string}") do |desc, target, dfn|
  @goal = Lakeraven::EHR::Goal.new(
    patient_dfn: dfn, description: desc, target_date: Date.parse(target)
  )
end

When("I serialize the goal to FHIR") do
  @fhir = @goal.to_fhir
end

Then("the goal should be valid") do
  assert @goal.valid?, "Expected valid: #{@goal.errors.full_messages}"
end

Then("the goal should be invalid") do
  refute @goal.valid?
end

Then("the goal should be active") do
  assert @goal.active?, "Expected active"
end

Then("the goal should be achieved") do
  assert @goal.achieved?, "Expected achieved"
end

Then("the FHIR goal lifecycle status should be {string}") do |expected|
  assert_equal expected, @fhir[:lifecycleStatus]
end

Then("the FHIR goal description should include {string}") do |text|
  desc = @fhir[:description]
  refute_nil desc
  assert_includes desc[:text], text
end
