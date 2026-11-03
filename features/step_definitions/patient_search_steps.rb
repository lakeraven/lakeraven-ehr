# frozen_string_literal: true

# Patient Search Steps — lakeraven-ehr

# Patients come from "these RPMS demo patients:" (rpms_demo_patient_steps.rb).

When("I search for patients with name {string}") do |name|
  @search_results = Lakeraven::EHR::Patient.search(name)
end

When("I search for patients with SSN {string}") do |ssn|
  @search_results = Lakeraven::EHR::Patient.search_by_ssn(ssn)
end

When("I retrieve patient with DFN {int}") do |dfn|
  @current_patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
end

When("I view the patient's referrals") do
  @patient_referrals = @current_patient&.service_requests || []
end

Then("I should find {int} patient(s) in the results") do |count|
  assert_equal count, @search_results.length
end

Then("the patient results should include {string}") do |name|
  assert @search_results.any? { |p| p.name == name },
         "Expected results to include #{name}, got: #{@search_results.map(&:name)}"
end

Then("the patient should have name {string}") do |name|
  assert @search_results.any? { |p| p.name == name },
         "Expected a patient named #{name}"
end

Then("I should see patient {string}") do |name|
  assert_equal name, @current_patient.name
end

Then("the patient demographics should show:") do |table|
  table.rows_hash.each do |field, value|
    case field
    when "Date of Birth"
      assert_equal value, @current_patient.dob.strftime("%m/%d/%Y")
    when "Sex"
      sex_display = case @current_patient.sex&.upcase
      when "M" then "Male"
      when "F" then "Female"
      else "Unknown"
      end
      assert_equal value, sex_display
    when "SSN"
      assert_equal value, @current_patient.ssn
    when "Service Area"
      assert_equal value, @current_patient.service_area
    end
  end
end

Then("I should see at least {int} referral(s)") do |min_count|
  assert @patient_referrals.length >= min_count,
         "Expected at least #{min_count} referral(s), got #{@patient_referrals.length}"
end

Then("the patient should be nil") do
  assert_nil @current_patient
end

# The pinned build has no demo referral, and the engine cannot file one yet:
# ServiceRequestGateway.create calls a removed path (lakeraven-ehr#521). A
# referral seeded into the mock alone would be data RPMS does not have.
Given("patient {int} has referrals seeded") do |_dfn|
  pending "no demo referral on the pinned build; filing one needs lakeraven-ehr#521"
end
