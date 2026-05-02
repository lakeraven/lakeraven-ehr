# frozen_string_literal: true

# SMART launch context step definitions

Given("an OAuth application {string}") do |app_uid|
  @oauth_app_uid = app_uid
end

When("I mint a launch context for patient {string}") do |dfn|
  @launch_context = Lakeraven::EHR::LaunchContext.mint(
    oauth_application_uid: @oauth_app_uid, patient_dfn: dfn
  )
end

When("I mint a launch context for patient {string} and encounter {string}") do |dfn, encounter_id|
  @launch_context = Lakeraven::EHR::LaunchContext.mint(
    oauth_application_uid: @oauth_app_uid, patient_dfn: dfn, encounter_id: encounter_id
  )
end

When("I mint a launch context for patient {string} with facility {string}") do |dfn, facility|
  @launch_context = Lakeraven::EHR::LaunchContext.mint(
    oauth_application_uid: @oauth_app_uid, patient_dfn: dfn, facility_identifier: facility
  )
end

When("I mint a launch context without a patient") do
  @launch_context = Lakeraven::EHR::LaunchContext.mint(
    oauth_application_uid: @oauth_app_uid
  )
end

When("I mint two launch contexts for patient {string}") do |dfn|
  @launch_context_1 = Lakeraven::EHR::LaunchContext.mint(
    oauth_application_uid: @oauth_app_uid, patient_dfn: dfn
  )
  @launch_context_2 = Lakeraven::EHR::LaunchContext.mint(
    oauth_application_uid: @oauth_app_uid, patient_dfn: dfn
  )
end

Then("the launch context should have a token") do
  refute_nil @launch_context.launch_token
end

Then("the launch context token should start with {string}") do |prefix|
  assert @launch_context.launch_token.start_with?(prefix),
    "Expected token to start with '#{prefix}', got '#{@launch_context.launch_token}'"
end

Then("the launch context should expire in the future") do
  assert @launch_context.expires_at > Time.current, "Expected expires_at in the future"
end

Then("the SMART context should include patient {string}") do |dfn|
  context = @launch_context.to_smart_context
  assert_equal dfn, context[:patient]
end

Then("the SMART context should include encounter {string}") do |encounter_id|
  context = @launch_context.to_smart_context
  assert_equal encounter_id, context[:encounter]
end

Then("the launch context facility should be {string}") do |expected|
  assert_equal expected, @launch_context.facility_identifier
end

Then("the SMART context should not include patient") do
  context = @launch_context.to_smart_context
  refute context.key?(:patient), "Expected no patient in SMART context"
end

Then("the SMART context should not include encounter") do
  context = @launch_context.to_smart_context
  refute context.key?(:encounter), "Expected no encounter in SMART context"
end

Then("the tokens should be different") do
  refute_equal @launch_context_1.launch_token, @launch_context_2.launch_token
end
