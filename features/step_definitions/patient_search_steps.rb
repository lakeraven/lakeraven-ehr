# frozen_string_literal: true

# Patient Search Steps — lakeraven-ehr

# The table is what the pinned RPMS build holds. Against the mock it is seeded
# into each RPC the patient reads use; against RPMS (LIVE_RPMS=1) each row is
# checked, so a row RPMS disagrees with fails the scenario instead of drifting.
Given("these RPMS demo patients:") do |table|
  rows = table.hashes.map do |r|
    { dfn: r["dfn"].to_i, name: r["name"], ssn: r["ssn"], dob: Date.parse(r["dob"]), sex: r["sex"] }
  end

  if LIVE_RPMS
    rows.each do |row|
      found = RpmsRpc::Patient.find(row[:dfn])
      assert found, "RPMS has no patient DFN #{row[:dfn]}"
      assert_equal row.except(:dfn), found.slice(:name, :ssn, :dob, :sex),
                   "RPMS disagrees with the table for DFN #{row[:dfn]}"
    end
  else
    mock = RpmsRpc.client
    rows.each do |row|
      mock.seed(:patient_select, row[:dfn].to_s, row.except(:dfn))
      mock.seed(:patient_id_info, row[:dfn].to_s, row.slice(:ssn, :dob, :sex, :name))
      mock.seed(:patient_ssn, row[:ssn], row.slice(:dfn, :name, :dob, :ssn))
    end
    # ORWPT LIST ALL answers a page of the name index whatever the start text
    # (rpms-rpc #352); the gateway does the prefix filtering.
    mock.seed_collection(:patient_list, rows.sort_by { |r| r[:name] }.map { |r| r.slice(:dfn, :name) })
  end
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
