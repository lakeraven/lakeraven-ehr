# frozen_string_literal: true

# Provider Search Steps — lakeraven-ehr

# Names demo providers in the feature's own words; the rows must match
# features/support/rpms_demo_site.rb (checked against RPMS on a live run).
Given("these RPMS demo providers:") do |table|
  rows = table.hashes.map { |r| { ien: r["ien"], name: r["name"] } }
  assert_equal RpmsDemoSite::PROVIDERS, rows, "The table differs from the demo site"
end

When("I search for providers with name {string}") do |name|
  @provider_results = Lakeraven::EHR::Practitioner.search(name)
end

When("I search for all providers") do
  @provider_results = Lakeraven::EHR::Practitioner.search("")
end

When("I retrieve provider with IEN {int}") do |ien|
  @current_provider = Lakeraven::EHR::Practitioner.find_by_ien(ien)
end

When("I search for providers who can prescribe controlled substances") do
  search_results = Lakeraven::EHR::Practitioner.search("")
  # Search returns minimal data; full lookup needed for DEA check
  full_providers = search_results.filter_map { |p| Lakeraven::EHR::Practitioner.find_by_ien(p.ien) }
  @provider_results = full_providers.select(&:can_prescribe_controlled?)
end

Then("I should find {int} provider(s) in the results") do |count|
  assert_equal count, @provider_results.length
end

Then("the provider results should include {string}") do |name|
  assert @provider_results.any? { |p| p.name == name },
         "Expected results to include #{name}, got: #{@provider_results.map(&:name)}"
end

Then("the provider results should not include {string}") do |name|
  refute @provider_results.any? { |p| p.name == name },
         "Expected results NOT to include #{name}"
end

Then("I should see provider {string}") do |name|
  assert_equal name, @current_provider.name
end

Then("the provider details should show:") do |table|
  table.rows_hash.each do |field, value|
    case field
    when "Specialty"
      assert_equal value, @current_provider.specialty
    when "NPI"
      assert_equal value, @current_provider.npi
    when "DEA"
      assert_equal value, @current_provider.dea_number
    end
  end
end

Then("the provider should be nil") do
  assert_nil @current_provider
end

Then("the provider should be able to prescribe controlled substances") do
  assert @current_provider.can_prescribe_controlled?,
         "Expected provider to have DEA number"
end
