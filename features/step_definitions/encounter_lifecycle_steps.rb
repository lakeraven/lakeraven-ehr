# frozen_string_literal: true

Given("a patient with DFN {int}") do |dfn|
  @dfn = dfn
end

Given("the patient has an active encounter with visit IEN {int}") do |visit_ien|
  @visit_ien = visit_ien
end

Given("the encounter is at location {string} with provider {string}") do |location, provider|
  @expected_location = location
  @expected_provider = provider
  install_encounter_stub
end

Given("the encounter is missing the {string} and {string} components") do |a, b|
  @expected_missing = [ a, b ]
  install_encounter_stub
end

Given("the patient's brief header is name {string} sex {string} mrn {string}") do |name, sex, mrn|
  @brief_header = { name: name, sex: sex, mrn: mrn, dob: nil, age: nil,
                    allergy_flag: false, ad_flag: false, primary_provider: nil }
  stub_gateway(Lakeraven::EHR::PatientGateway, :brief_header, @brief_header)
end

Given("the patient has {int} vitals and {int} problem(s) on file") do |vitals_count, problems_count|
  vitals = Array.new(vitals_count) { |i| { type: "V#{i}", value: i } }
  problems = Array.new(problems_count) { |i| { ien: i + 1, description: "Problem #{i + 1}" } }
  stub_gateway(Lakeraven::EHR::ObservationGateway, :for_patient, vitals)
  stub_gateway(Lakeraven::EHR::ConditionGateway, :for_patient, problems)
end

Given("the encounter has {int} active reminder(s)") do |count|
  reminders = Array.new(count) { |i| { id: i + 1, name: "Reminder #{i + 1}", status: :due } }
  stub_gateway(Lakeraven::EHR::RemindersGateway, :for_visit, reminders)
end

Given("the patient has {int} active allergy(ies)") do |count|
  allergies = Array.new(count) { |i| { allergen: "Allergen#{i + 1}", reaction: "Reaction#{i + 1}", severity: "Severe" } }
  stub_gateway(Lakeraven::EHR::AllergyIntoleranceGateway, :for_patient, allergies)
end

Given("the requesting provider lacks the view-patients capability") do
  @requester = Object.new
  def @requester.can?(_perm); false; end
end

When("the provider opens encounter {int} for patient {int}") do |visit_ien, dfn|
  service = Lakeraven::EHR::EncounterLifecycleService.new(dfn, visit_ien, requester: @requester)
  @open_result = service.open
end

Then("the open call should succeed") do
  assert @open_result.success?, "Expected open to succeed, got: #{@open_result.error}"
end

Then("the open call should fail with a not-found result") do
  refute @open_result.success?
  assert_equal :not_found, @open_result.error
end

Then("the open call should fail with a permission-denied result") do
  refute @open_result.success?
  assert_equal :permission_denied, @open_result.error
end

Then("the encounter context should show location {string}") do |location|
  assert_equal location, @open_result.context[:encounter][:location]
end

Then("the encounter context should show provider {string}") do |provider|
  assert_equal provider, @open_result.context[:encounter][:provider]
end

Then("the encounter context should show status {string}") do |status|
  assert_equal status, @open_result.context[:encounter][:status]
end

Then("the encounter context should list {int} missing components") do |count|
  assert_equal count, @open_result.context[:encounter][:missing_components].length
end

Then("the open result should include the patient brief header with name {string}") do |name|
  brief = @open_result.context[:brief_header]
  refute_nil brief, "Expected brief_header in open result"
  assert_equal name, brief[:name]
end

Then("the open result should include {int} vitals") do |count|
  assert_equal count, @open_result.context[:vitals].length
end

Then("the open result should include {int} problem(s)") do |count|
  assert_equal count, @open_result.context[:problems].length
end

Then("the open result should include {int} reminder(s)") do |count|
  assert_equal count, @open_result.context[:reminders].length
end

Then("the open result should include {int} allergy(ies)") do |count|
  assert_equal count, @open_result.context[:allergies].length
end

# Helper — installs the EncounterGateway.open stub keyed on the current
# scenario's @dfn / @visit_ien. Uses define_singleton_method directly so
# the stub is key-aware (returns nil for the "non-existent encounter"
# scenario). Restoration is handled by features/support/gateway_stubs.rb
# via the stub_gateway placeholder call.
def install_encounter_stub
  encounter = {
    visit_ien: @visit_ien,
    patient_dfn: @dfn,
    location: @expected_location,
    provider: @expected_provider,
    status: "A",
    missing_components: (@expected_missing || []).map { |c| { component: c, message: "Visit has no note" } }
  }
  expected_dfn = @dfn
  expected_visit = @visit_ien
  # Register restore via stub_gateway, then immediately replace with the
  # key-aware version (the placeholder return value is overwritten below).
  stub_gateway(Lakeraven::EHR::EncounterGateway, :open, nil)
  Lakeraven::EHR::EncounterGateway.define_singleton_method(:open) do |req_dfn, req_visit|
    next nil unless req_dfn == expected_dfn && req_visit == expected_visit
    encounter
  end
end
