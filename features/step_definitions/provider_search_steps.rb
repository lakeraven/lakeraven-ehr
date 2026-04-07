# frozen_string_literal: true

Given("the following practitioners are registered at facility {string}:") do |facility_identifier, table|
  table.hashes.each do |row|
    Lakeraven::EHR.adapter.seed_practitioner(
      tenant_identifier: Lakeraven::EHR::Current.tenant_identifier || "tnt_test",
      facility_identifier: facility_identifier,
      display_name: row["display_name"],
      specialty: row["specialty"],
      identifiers: row["npi"] ? [ { system: "http://hl7.org/fhir/sid/us-npi", value: row["npi"] } ] : []
    )
  end
end

When("I search for practitioners by name {string}") do |name|
  @provider_search_error = nil
  @provider_search_results = Lakeraven::EHR::ProviderSearch.call(name: name)
rescue Lakeraven::EHR::MissingTenantContextError => e
  @provider_search_error = e
end

When("I search for practitioners by specialty {string}") do |specialty|
  @provider_search_error = nil
  @provider_search_results = Lakeraven::EHR::ProviderSearch.call(specialty: specialty)
rescue Lakeraven::EHR::MissingTenantContextError => e
  @provider_search_error = e
end

When("I search for practitioners with identifier system {string} and value {string}") do |system, value|
  @provider_search_error = nil
  @provider_search_results = Lakeraven::EHR::ProviderSearch.call(identifier_system: system, identifier_value: value)
rescue Lakeraven::EHR::MissingTenantContextError => e
  @provider_search_error = e
end

When("I search for practitioners with no filter") do
  @provider_search_error = nil
  @provider_search_results = Lakeraven::EHR::ProviderSearch.call
rescue Lakeraven::EHR::MissingTenantContextError => e
  @provider_search_error = e
end

Then("the practitioner search returns {int} practitioner(s)") do |count|
  assert_nil @provider_search_error, "expected no error but got #{@provider_search_error&.class}: #{@provider_search_error&.message}"
  assert_equal count, @provider_search_results.length
end

Then("the result includes a practitioner with display name {string}") do |display_name|
  display_names = @provider_search_results.map { |r| r[:display_name] }
  assert_includes display_names, display_name
end

Then('every practitioner result has an opaque practitioner_identifier prefixed with {string}') do |prefix|
  @provider_search_results.each do |result|
    assert result[:practitioner_identifier].start_with?(prefix),
      "expected practitioner_identifier to start with #{prefix}, got #{result[:practitioner_identifier]}"
  end
end

Then("no practitioner result exposes a backend-native IEN") do
  @provider_search_results.each do |result|
    normalized_keys = result.keys.map { |k| k.to_s.downcase }
    refute_includes normalized_keys, "ien"
  end
end

Then("the practitioner search succeeds without raising") do
  assert_nil @provider_search_error
end

Then("the practitioner search raises a missing-tenant-context error") do
  assert_kind_of Lakeraven::EHR::MissingTenantContextError, @provider_search_error
end
