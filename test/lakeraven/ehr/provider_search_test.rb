# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::ProviderSearchTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
    Lakeraven::EHR.configure do |config|
      config.adapter = Lakeraven::EHR::Adapters::MockAdapter.new
    end
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    Lakeraven::EHR::Current.facility_identifier = "fac_main"

    @adapter = Lakeraven::EHR.adapter
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology",
                               identifiers: [ { system: "http://hl7.org/fhir/sid/us-npi", value: "1234567890" } ])
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "CHEN,JAMES", specialty: "Orthopedic Surgery",
                               identifiers: [ { system: "http://hl7.org/fhir/sid/us-npi", value: "2345678901" } ])
  end

  teardown do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
  end

  test "ProviderSearch.call delegates to the configured adapter" do
    results = Lakeraven::EHR::ProviderSearch.call(name: "MARTINEZ")
    assert_equal 1, results.length
    assert_equal "MARTINEZ,SARAH", results.first[:display_name]
  end

  test "ProviderSearch passes the current tenant_identifier to the adapter" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_other", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    results = Lakeraven::EHR::ProviderSearch.call(name: "MARTINEZ")
    assert_equal 1, results.length, "expected tnt_other practitioner to be filtered out by tenant scope"
  end

  test "ProviderSearch passes the current facility_identifier when set" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                               display_name: "OTHER,PROVIDER", specialty: "Dermatology")
    Lakeraven::EHR::Current.facility_identifier = "fac_main"
    results = Lakeraven::EHR::ProviderSearch.call(name: "PROVIDER")
    assert_equal 0, results.length
  end

  test "ProviderSearch returns all facilities when current facility is unset" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                               display_name: "OTHER,PROVIDER", specialty: "Dermatology")
    Lakeraven::EHR::Current.facility_identifier = nil
    results = Lakeraven::EHR::ProviderSearch.call(name: "PROVIDER")
    assert_equal 1, results.length
  end

  test "ProviderSearch by specialty filters correctly" do
    results = Lakeraven::EHR::ProviderSearch.call(specialty: "Cardiology")
    assert_equal 1, results.length
    assert_equal "MARTINEZ,SARAH", results.first[:display_name]
  end

  test "ProviderSearch by NPI identifier filters correctly" do
    results = Lakeraven::EHR::ProviderSearch.call(
      identifier_system: "http://hl7.org/fhir/sid/us-npi",
      identifier_value: "2345678901"
    )
    assert_equal 1, results.length
    assert_equal "CHEN,JAMES", results.first[:display_name]
  end

  test "ProviderSearch with no filter returns all practitioners in scope" do
    results = Lakeraven::EHR::ProviderSearch.call
    assert_equal 2, results.length
  end

  test "ProviderSearch raises MissingTenantContextError when tenant is unset" do
    Lakeraven::EHR::Current.tenant_identifier = nil
    assert_raises(Lakeraven::EHR::MissingTenantContextError) do
      Lakeraven::EHR::ProviderSearch.call(name: "MARTINEZ")
    end
  end

  test "ProviderSearch returns an empty array (not nil) for no matches" do
    result = Lakeraven::EHR::ProviderSearch.call(name: "NONEXISTENT")
    assert_equal [], result
  end

  test "ProviderSearch raises NotConfiguredError when adapter is missing" do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    assert_raises(Lakeraven::EHR::NotConfiguredError) do
      Lakeraven::EHR::ProviderSearch.call(name: "MARTINEZ")
    end
  end
end
