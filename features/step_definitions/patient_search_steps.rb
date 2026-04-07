# frozen_string_literal: true

Given("the EHR adapter is the in-memory mock") do
  Lakeraven::EHR.configure do |config|
    config.adapter = Lakeraven::EHR::Adapters::MockAdapter.new
  end
end

Given("the current tenant is {string}") do |tenant_identifier|
  Lakeraven::EHR::Current.tenant_identifier = tenant_identifier
end

Given("the current tenant is unset") do
  Lakeraven::EHR::Current.tenant_identifier = nil
end

Given("the current facility is {string}") do |facility_identifier|
  Lakeraven::EHR::Current.facility_identifier = facility_identifier
end

Given("the current facility is unset") do
  Lakeraven::EHR::Current.facility_identifier = nil
end

Given("the following patients are registered at facility {string}:") do |facility_identifier, table|
  table.hashes.each do |row|
    Lakeraven::EHR.adapter.seed_patient(
      tenant_identifier: Lakeraven::EHR::Current.tenant_identifier || "tnt_test",
      facility_identifier: facility_identifier,
      display_name: row["display_name"],
      date_of_birth: Date.parse(row["date_of_birth"]),
      gender: row["gender"]
    )
  end
end

When("I search for patients by name {string}") do |name|
  @search_error = nil
  @search_results = Lakeraven::EHR::PatientSearch.call(name: name)
rescue Lakeraven::EHR::MissingTenantContextError => e
  @search_error = e
end

Then("the search returns {int} patient(s)") do |count|
  assert_nil @search_error, "expected no error but got #{@search_error&.class}: #{@search_error&.message}"
  assert_equal count, @search_results.length
end

Then("the result includes a patient with display name {string}") do |display_name|
  display_names = @search_results.map { |r| r[:display_name] }
  assert_includes display_names, display_name
end

Then('every result has an opaque patient_identifier prefixed with {string}') do |prefix|
  @search_results.each do |result|
    assert result[:patient_identifier].start_with?(prefix),
      "expected patient_identifier to start with #{prefix}, got #{result[:patient_identifier]}"
  end
end

Then("no result exposes a backend-native DFN") do
  @search_results.each do |result|
    refute_includes result.keys, :dfn
    refute_includes result.keys, "dfn"
    refute_includes result.keys, :DFN
  end
end

Then("the search succeeds without raising") do
  assert_nil @search_error
end

Then("the search raises a missing-tenant-context error") do
  assert_kind_of Lakeraven::EHR::MissingTenantContextError, @search_error
end
