# frozen_string_literal: true

# Patient Search Steps — lakeraven-ehr
# Data comes from RpmsRpc.mock! seeds in test_helper.rb

Given("the following patients are seeded:") do |_table|
  # Data is pre-seeded via RpmsRpc.mock! in test_helper.rb.
  # The table documents what's available; no runtime action needed.
end

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

Given("patient {int} has referrals seeded") do |dfn|
  mock = RpmsRpc.client
  mock.seed_collection(:referral_search, [
    { ien: 1, patient_dfn: dfn, status: "PENDING", type: "CONSULT",
      date: Date.current, provider: "MARTINEZ,SARAH" }
  ])
end
