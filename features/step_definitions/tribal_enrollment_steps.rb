# frozen_string_literal: true

# Migrated for rpms-rpc 0.3.0 (#235): tribal reads are real DDR FileMan reads,
# stubbed here at the TribalEnrollmentGateway boundary (stub_gateway,
# features/support/gateway_stubs.rb) exactly as the model tests do. The
# fail-closed contract under test lives in Patient: an undetermined
# eligibility_status NEVER resolves to "eligible" (see #520 for the parked
# I/D/C/P → determination mapping).

TRIBAL_GW = Lakeraven::EHR::TribalEnrollmentGateway

def tribal_patient(dfn, enrollment: "EXNH-12345")
  Lakeraven::EHR::Patient.new(dfn: dfn.to_i, name: "TEST,PATIENT", sex: "F",
                              tribal_enrollment_number: enrollment)
end

# -- enrollment details ------------------------------------------------------

Given("the enrollment read for patient {string} returns:") do |dfn, table|
  projection = table.rows_hash.transform_keys(&:to_sym)
  projection[:tribe_ien] = projection[:tribe_ien].to_i if projection[:tribe_ien]
  stub_gateway(TRIBAL_GW, :enrollment_details, projection)
  @patient = tribal_patient(dfn)
end

When("I request tribal enrollment details for patient {string}") do |dfn|
  @patient ||= tribal_patient(dfn)
  @tribal_details = @patient.tribal_enrollment_details
end

Then("I should see tribal enrollment information:") do |table|
  table.rows_hash.each do |key, value|
    assert_equal value, @tribal_details[key.to_sym].to_s, "Mismatch on #{key}"
  end
end

# -- validation (syntactic) --------------------------------------------------

Given("the server accepts enrollment number {string} as internal {string}") do |number, internal|
  stub_gateway(TRIBAL_GW, :validate, { valid: true, internal: internal, external: number })
end

Given("the server rejects enrollment number {string}") do |_number|
  stub_gateway(TRIBAL_GW, :validate, { valid: false, internal: nil, external: nil })
end

When("I validate tribal enrollment number {string}") do |number|
  @validation = tribal_patient(1, enrollment: number).validate_tribal_enrollment
end

Then("the enrollment should be valid") do
  assert @validation[:valid]
end

Then("the enrollment should not be valid") do
  refute @validation[:valid]
end

# -- eligibility (FAIL CLOSED) -----------------------------------------------

Given("the eligibility read for patient {string} returns status {string} classified {string}") do |dfn, status, classification|
  stub_gateway(TRIBAL_GW, :eligibility,
               { eligibility_status: status, eligibility_status_name: nil,
                 classification_ien: nil, classification: classification })
  @patient = tribal_patient(dfn)
end

Given("the eligibility read for patient {string} returns nothing") do |dfn|
  stub_gateway(TRIBAL_GW, :eligibility, nil)
  @patient = tribal_patient(dfn)
end

Given("patient {string} has no enrollment number on file") do |dfn|
  @patient = tribal_patient(dfn, enrollment: nil)
end

When("I check IHS eligibility for patient {string}") do |_dfn|
  @eligibility = @patient.tribal_enrollment_eligibility
end

Then("the eligibility determination should be undetermined") do
  assert_equal :undetermined, @eligibility[:determination]
  refute @eligibility[:eligible]
end

Then("the raw eligibility status should be {string}") do |status|
  assert_equal status, @eligibility[:eligibility_status]
end

Then("the patient should not be eligible for IHS services") do
  refute @patient.eligible_for_ihs_services?
end

# PARKED on #520 — mirrors the model test's skip: no I/D/C/P code may be
# asserted eligible until the compliance mapping is signed off.
When("the signed-off eligibility mapping is required") do
  skip_this_scenario("eligibility_status (I/D/C/P) → IHS-eligibility mapping is a " \
                     "compliance decision tracked in #520; fail-closed until signed off")
end

Then("the patient can be determined eligible for IHS services") do
  raise "unreachable until #520 lands the signed-off mapping"
end

# -- service unit (table lookup by IEN) --------------------------------------

Given("service unit {int} is named {string}") do |ien, name|
  stub_gateway(TRIBAL_GW, :service_unit, { ien: ien, name: name })
end

When("I look up service unit {int}") do |ien|
  @service_unit = TRIBAL_GW.service_unit(ien)
end

Then("I should see service unit information:") do |table|
  table.rows_hash.each do |key, value|
    assert_equal value, @service_unit[key.to_sym].to_s
  end
end

# -- tribe information (via the enrollment's TRIBE pointer) ------------------

Given("the enrollment read for patient {string} returns tribe pointer {int}") do |dfn, tribe_ien|
  stub_gateway(TRIBAL_GW, :enrollment_details, { tribe_ien: tribe_ien })
  @patient = tribal_patient(dfn)
end

Given("the enrollment read for patient {string} returns no tribe pointer") do |dfn|
  stub_gateway(TRIBAL_GW, :enrollment_details, { tribe_ien: nil })
  @patient = tribal_patient(dfn)
end

Given("tribe {int} is {string} with code {string}") do |ien, name, code|
  stub_gateway(TRIBAL_GW, :tribe_info, { ien: ien, name: name, code: code })
end

When("I request tribe information for patient {string}") do |_dfn|
  @tribe_info = @patient.tribe_information
end

Then("I should see tribe details:") do |table|
  table.rows_hash.each do |key, value|
    assert_equal value, @tribe_info[key.to_sym].to_s
  end
end

Then("no tribe information should be available") do
  assert_nil @tribe_info
end

# -- validation error path ---------------------------------------------------

When("I attempt to validate the patient's tribal enrollment") do
  @validation = @patient.validate_tribal_enrollment
end

Then("I should see an error message {string}") do |message|
  assert_includes @validation[:message], message
end

Then("the validation should indicate invalid") do
  refute @validation[:valid]
end
