# frozen_string_literal: true

# CareTeam step definitions

Given("a care team with name {string} for patient {string}") do |name, dfn|
  @care_team = Lakeraven::EHR::CareTeam.new(patient_dfn: dfn, name: name, status: "active")
end

Given("a care team without a patient") do
  @care_team = Lakeraven::EHR::CareTeam.new(name: "Test Team", status: "active")
end

Given("the care team has a participant with duz {string} and role {string}") do |duz, role|
  @care_team.participants << { "duz" => duz, "name" => "Provider #{duz}", "role" => role }
end

When("I serialize the care team to FHIR") do
  @fhir = @care_team.to_fhir
end

Then("the care team should be valid") do
  assert @care_team.valid?, "Expected valid: #{@care_team.errors.full_messages}"
end

Then("the care team should be invalid") do
  refute @care_team.valid?
end

Then("the FHIR care team subject reference should include {string}") do |dfn|
  subject = @fhir[:subject]
  refute_nil subject
  assert_includes subject[:reference], dfn
end

Then("the FHIR care team should have participants") do
  participants = @fhir[:participant]
  refute_nil participants
  refute participants.empty?, "Expected at least one participant"
end

Then("the FHIR care team name should be {string}") do |expected|
  assert_equal expected, @fhir[:name]
end
