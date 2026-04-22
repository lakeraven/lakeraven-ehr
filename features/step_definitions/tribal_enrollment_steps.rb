# frozen_string_literal: true

When("I request tribal enrollment details for patient {string}") do |dfn|
  @tribal_details = Lakeraven::EHR::TribalEnrollmentGateway.enrollment_details(dfn)
end

Then("I should see tribal enrollment information:") do |table|
  expected = table.rows_hash
  expected.each do |key, value|
    assert_equal value, @tribal_details[key.to_sym].to_s, "Mismatch on #{key}"
  end
end

Then("the enrollment date should be present") do
  assert @tribal_details[:enrollment_date].present?
end

When("I validate tribal enrollment number {string}") do |number|
  @validation = Lakeraven::EHR::TribalEnrollmentGateway.validate(number)
end

Then("the enrollment should be valid") do
  assert @validation[:valid]
end

Then("the enrollment should not be valid") do
  refute @validation[:valid]
end

Then("the tribe code should be {string}") do |code|
  assert_equal code, @validation[:tribe_code]
end

Then("the status should be {string}") do |status|
  assert_equal status, @validation[:status]
end

Then("I should see the message {string}") do |message|
  assert_equal message, @validation[:message]
end

When("I check IHS eligibility for patient {string}") do |dfn|
  @eligibility = Lakeraven::EHR::TribalEnrollmentGateway.eligibility(dfn)
end

Then("the patient should be eligible for IHS services") do
  assert @eligibility[:active] && @eligibility[:eligible_for_ihs]
end

Then("the patient should not be eligible for IHS services") do
  refute @eligibility[:active] && @eligibility[:eligible_for_ihs]
end

Then("the eligibility should show:") do |table|
  expected = table.rows_hash
  expected.each do |key, value|
    actual = @eligibility[key.to_sym]
    expected_val = case value
    when "true" then true
    when "false" then false
    else value
    end
    assert_equal expected_val, actual, "Mismatch on #{key}: expected #{expected_val.inspect}, got #{actual.inspect}"
  end
end

When("I request the service unit for patient {string}") do |dfn|
  @service_unit = Lakeraven::EHR::TribalEnrollmentGateway.service_unit(dfn)
end

Then("I should see service unit information:") do |table|
  expected = table.rows_hash
  expected.each do |key, value|
    assert_equal value, @service_unit[key.to_sym].to_s
  end
end

When("I request tribe information for {string}") do |code|
  @tribe_info = Lakeraven::EHR::TribalEnrollmentGateway.tribe_info(code)
end

Then("I should see tribe details:") do |table|
  expected = table.rows_hash
  expected.each do |key, value|
    assert_equal value, @tribe_info[key.to_sym].to_s
  end
end

Given("I have patient {string} with enrollment {string}") do |dfn, enrollment|
  @patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
  @patient.tribal_enrollment_number = enrollment if @patient
end

Given("I have patient {string} with no enrollment number") do |dfn|
  @patient = Lakeraven::EHR::Patient.new(dfn: dfn.to_i, name: "TEST,PATIENT", sex: "F")
  @patient.tribal_enrollment_number = nil
end

When("I check if the patient's tribal enrollment is valid") do
  @enrollment_valid = @patient.tribal_enrollment_valid?
end

Then("the enrollment validation should return true") do
  assert @enrollment_valid
end

When("I check if the patient is eligible for IHS services") do
  @ihs_eligible = @patient.eligible_for_ihs_services?
end

Then("the patient eligibility should return true") do
  assert @ihs_eligible
end

When("I request tribe information for the following codes:") do |table|
  @tribe_results = table.hashes.map do |row|
    Lakeraven::EHR::TribalEnrollmentGateway.tribe_info(row["tribe_code"])
  end
end

Then("I should receive tribe information for all codes") do
  @tribe_results.each { |r| assert r.present?, "Expected tribe info" }
end

Then("each tribe should have:") do |table|
  fields = table.hashes.map { |r| r.values.first.to_sym }
  @tribe_results.each do |tribe|
    fields.each { |f| assert tribe[f].present?, "Missing #{f} in tribe info" }
  end
end

When("I request tribe information for the patient") do
  @tribe_info = @patient.tribe_information
  @extracted_code = @patient.tribal_enrollment_number&.split("-")&.first
end

Then("the tribe code should be extracted as {string}") do |code|
  assert_equal code, @extracted_code
end

Then("I should see the full tribe information") do
  assert @tribe_info.present?
  assert @tribe_info[:name].present?
end

When("I attempt to validate the patient's tribal enrollment") do
  @validation = @patient.validate_tribal_enrollment
end

Then("I should see an error message {string}") do |message|
  assert_equal message, @validation[:message]
end

Then("the validation should indicate invalid") do
  refute @validation[:valid]
end

Given("I create a service request for specialty care") do
  @service_request_created = true
end

When("the eligibility service checks tribal enrollment") do
  @tribal_check_passed = @patient.tribal_enrollment_valid?
end

Then("the tribal enrollment check should pass") do
  assert @tribal_check_passed
end

Then("the service request should proceed to next eligibility step") do
  assert @tribal_check_passed && @service_request_created
end
