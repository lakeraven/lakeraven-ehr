# frozen_string_literal: true

# Consent step definitions

Given("a consent with scope {string} and status {string} for patient {string}") do |scope, status, dfn|
  @consent = Lakeraven::EHR::Consent.new(
    patient_dfn: dfn, scope: scope, status: status, provision_type: "permit"
  )
end

Given("a consent with scope {string} and status {string} and provision {string} for patient {string}") do |scope, status, provision, dfn|
  @consent = Lakeraven::EHR::Consent.new(
    patient_dfn: dfn, scope: scope, status: status, provision_type: provision
  )
end

Given("a consent without a patient") do
  @consent = Lakeraven::EHR::Consent.new(scope: "patient-privacy", status: "active")
end

Given("a consent without a scope for patient {string}") do |dfn|
  @consent = Lakeraven::EHR::Consent.new(patient_dfn: dfn, status: "active")
end

Given("a consent with provision type {string} for patient {string}") do |provision, dfn|
  @consent = Lakeraven::EHR::Consent.new(
    patient_dfn: dfn, scope: "patient-privacy", status: "active", provision_type: provision
  )
end

Given("a consent with period from {string} to {string} for patient {string}") do |start_date, end_date, dfn|
  @consent = Lakeraven::EHR::Consent.new(
    patient_dfn: dfn, scope: "patient-privacy", status: "active",
    period_start: Date.parse(start_date), period_end: Date.parse(end_date)
  )
end

When("I serialize the consent to FHIR") do
  @fhir = @consent.to_fhir
end

Then("the consent should be valid") do
  assert @consent.valid?, "Expected consent to be valid but got errors: #{@consent.errors.full_messages}"
end

Then("the consent should be invalid") do
  refute @consent.valid?, "Expected consent to be invalid"
end

Then("there should be a consent error on {string}") do |field|
  assert @consent.errors[field.to_sym].any?, "Expected error on #{field}"
end

Then("the consent should be enforceable") do
  assert @consent.enforceable?, "Expected consent to be enforceable"
end

Then("the consent should not be enforceable") do
  refute @consent.enforceable?, "Expected consent to not be enforceable"
end

Then("the scope display should be {string}") do |expected|
  assert_equal expected, @consent.scope_display
end

Then("the consent should permit access") do
  assert @consent.permits?, "Expected consent to permit access"
end

Then("the consent should deny access") do
  assert @consent.denies?, "Expected consent to deny access"
end

Then("the consent should be within period") do
  assert @consent.within_period?, "Expected consent to be within period"
end

Then("the consent should not be within period") do
  refute @consent.within_period?, "Expected consent to not be within period"
end

# "the FHIR resourceType should be" defined in encounter_model_steps.rb

Then("the FHIR patient reference should be {string}") do |ref|
  assert_equal ref, @fhir[:patient][:reference]
end

Then("the FHIR scope should include code {string}") do |code|
  scope = @fhir[:scope]
  refute_nil scope
  assert scope[:coding].any? { |c| c[:code] == code }
end

Then("the FHIR category should be present") do
  refute_nil @fhir[:category]
  assert @fhir[:category].any?
end

Then("the FHIR provision type should be {string}") do |type|
  refute_nil @fhir[:provision]
  assert_equal type, @fhir[:provision][:type]
end

Then("the consent should authorize access") do
  assert @consent.authorizes_access?, "Expected consent to authorize access"
end

Then("the consent should not authorize access") do
  refute @consent.authorizes_access?, "Expected consent to not authorize access"
end

Then("the consent should allow {string}") do |permission|
  assert @consent.allows?(permission), "Expected consent to allow #{permission}"
end

Then("the consent should not allow {string}") do |permission|
  refute @consent.allows?(permission), "Expected consent to not allow #{permission}"
end
