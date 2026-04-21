# frozen_string_literal: true

Given("a new encounter with status {string} class_code {string} and patient_dfn {int}") do |status, class_code, dfn|
  @encounter = Lakeraven::EHR::Encounter.new(
    status: status.presence, class_code: class_code.presence, patient_dfn: dfn
  )
end

Given("an in-progress ambulatory encounter for patient {int}") do |dfn|
  @encounter = Lakeraven::EHR::Encounter.new(
    status: "in-progress", class_code: "AMB", patient_dfn: dfn
  )
end

Given("a finished ambulatory encounter for patient {int}") do |dfn|
  @encounter = Lakeraven::EHR::Encounter.new(
    status: "finished", class_code: "AMB", patient_dfn: dfn
  )
end

Given("a planned ambulatory encounter for patient {int}") do |dfn|
  @encounter = Lakeraven::EHR::Encounter.new(
    status: "planned", class_code: "AMB", patient_dfn: dfn
  )
end

Given("the encounter started at {string}") do |timestamp|
  @encounter.period_start = DateTime.parse(timestamp)
end

When("the provider closes the encounter with reason_code {string} reason_display {string}") do |code, display|
  @close_result = @encounter.close(reason_code: code, reason_display: display)
end

When("the provider attempts to close the encounter") do
  @close_result = @encounter.close
end

When("the provider cancels the encounter") do
  @encounter.cancel
end

When("the provider adds practitioner {string} as a participant") do |ien|
  @encounter.practitioner_identifier = ien
end

Then("the encounter should be valid") do
  assert @encounter.valid?, "Expected valid, got errors: #{@encounter.errors.full_messages}"
end

Then("the encounter should have {int} participant(s)") do |count|
  participants = [ @encounter.practitioner_identifier ].compact
  assert_equal count, participants.length
end

Then("the encounter reason_display should be {string}") do |expected|
  assert_equal expected, @encounter.reason_display
end

Then("the encounter should be finished") do
  assert @encounter.finished?
end

Then("the encounter should be cancelled") do
  assert @encounter.cancelled?
end

Then("the encounter practitioner_identifier should be {string}") do |expected|
  assert_equal expected, @encounter.practitioner_identifier
end

Then("the encounter should be ambulatory") do
  assert @encounter.ambulatory?
end

Then("the close should fail with {string}") do |message|
  assert_equal false, @close_result
  assert_includes @encounter.errors.full_messages.join, message
end
