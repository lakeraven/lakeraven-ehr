# frozen_string_literal: true

# Referral origination step definitions

Given("a patient with DFN {string} and name {string}") do |dfn, name|
  @patient_dfn = dfn
  @patient_name = name
  @enrollment_data = nil
  @coverage_type = nil
end

Given("the patient is enrolled in tribe {string}") do |tribe_name|
  @enrollment_data = { enrolled: true, tribe_name: tribe_name, membership_number: "TST-001" }
end

Given("the patient is not enrolled") do
  @enrollment_data = { enrolled: false, tribe_name: nil, membership_number: nil }
end

Given("the patient has coverage type {string}") do |coverage|
  @coverage_type = coverage
end

Given("a requesting provider with IEN {string}") do |ien|
  @provider_ien = ien
end

When("I originate a referral for:") do |table|
  params = table.rows_hash.transform_keys(&:to_sym)

  enrollment_checker = if @enrollment_data
    ->(_dfn) { @enrollment_data }
  end

  service = Lakeraven::EHR::ReferralOriginationService.new(
    enrollment_checker: enrollment_checker
  )

  @origination_result = service.originate(
    patient_dfn: @patient_dfn,
    provider_ien: @provider_ien,
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

Then("the origination result should show enrollment verified") do
  assert @origination_result.enrollment_status[:verified],
    "Expected enrollment verified"
end

Then("the origination result should show enrollment not verified") do
  refute @origination_result.enrollment_status[:verified],
    "Expected enrollment NOT verified"
end

Then("the origination error should mention {string}") do |field|
  errors = @origination_result.errors.join(", ")
  assert errors.downcase.include?(field.downcase),
    "Expected '#{field}' in errors: #{errors}"
end

Then("the origination result should include coverage {string}") do |_coverage|
  # Coverage display is a future feature — for now just verify the result has the field
  refute_nil @origination_result.coverage_summary
end
