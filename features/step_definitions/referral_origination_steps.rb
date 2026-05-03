# frozen_string_literal: true

# Referral origination step definitions

Given("a patient with DFN {string} and name {string}") do |dfn, name|
  @patient_dfn = dfn
  @patient_name = name
  @enrollment_data = nil
end

Given("the patient is enrolled in tribe {string}") do |tribe_name|
  @enrollment_data = { enrolled: true, tribe_name: tribe_name }
end

Given("the patient is not enrolled") do
  @enrollment_data = { enrolled: false, tribe_name: nil }
end

Given("a requesting provider with IEN {string}") do |ien|
  @provider_ien = ien
end

When("I originate a referral for:") do |table|
  params = table.rows_hash.transform_keys(&:to_sym)

  service = Lakeraven::EHR::ReferralOriginationService.new
  @origination_result = service.originate(
    patient_dfn: @patient_dfn,
    provider_ien: @provider_ien,
    params: params
  )
end

When("I originate a referral with enrollment check for:") do |table|
  params = table.rows_hash.transform_keys(&:to_sym)

  checker = ->(_dfn) { @enrollment_data }
  service = Lakeraven::EHR::ReferralOriginationService.new(enrollment_checker: checker)
  @origination_result = service.originate(
    patient_dfn: @patient_dfn,
    provider_ien: @provider_ien,
    params: params
  )
end

When("I originate a referral without a provider for:") do |table|
  params = table.rows_hash.transform_keys(&:to_sym)

  service = Lakeraven::EHR::ReferralOriginationService.new
  @origination_result = service.originate(
    patient_dfn: @patient_dfn,
    provider_ien: 0,
    params: params
  )
end

Then("the referral should be created successfully") do
  assert @origination_result.success?,
    "Expected success, errors: #{@origination_result.errors}"
end

Then("the referral should not be created") do
  refute @origination_result.success?
end

Then("the referral should have a service request identifier") do
  refute_nil @origination_result.service_request
end

Then("the origination result should include patient identifier {string}") do |dfn|
  assert_equal dfn, @origination_result.patient_identifier
end

Then("the service request urgency should be {string}") do |urgency|
  assert_equal urgency, @origination_result.service_request.urgency
end

Then("the origination error should mention {string}") do |field|
  errors = @origination_result.errors.join(", ")
  assert_includes errors, field
end

Then("the origination result should show enrollment verified") do
  refute_nil @origination_result.enrollment_status
  assert @origination_result.enrollment_status[:verified]
end

Then("the origination result should show enrollment not verified") do
  refute_nil @origination_result.enrollment_status
  refute @origination_result.enrollment_status[:verified]
end

Then("the origination result should not include enrollment status") do
  assert_nil @origination_result.enrollment_status
end
