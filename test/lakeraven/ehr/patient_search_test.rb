# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::PatientSearchTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
    Lakeraven::EHR.configure do |config|
      config.adapter = Lakeraven::EHR::Adapters::MockAdapter.new
    end
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    Lakeraven::EHR::Current.facility_identifier = "fac_main"

    @adapter = Lakeraven::EHR.adapter
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "JOHNSON,BOB", date_of_birth: Date.new(1990, 3, 10), gender: "male")
  end

  teardown do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
  end

  test "PatientSearch.call delegates to the configured adapter" do
    results = Lakeraven::EHR::PatientSearch.call(name: "DOE")
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:display_name]
  end

  test "PatientSearch passes the current tenant_identifier to the adapter" do
    # Seed an identically-named patient in a different tenant. If
    # PatientSearch ignored Current.tenant_identifier and passed nothing
    # (or the wrong value) through to the adapter, this would return 2.
    @adapter.seed_patient(tenant_identifier: "tnt_other", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    results = Lakeraven::EHR::PatientSearch.call(name: "DOE")
    assert_equal 1, results.length, "expected tnt_other patient to be filtered out by tenant scope"
  end

  test "PatientSearch passes the current facility_identifier when set" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                          display_name: "OTHER,PERSON", date_of_birth: Date.new(1985, 12, 5), gender: "male")
    Lakeraven::EHR::Current.facility_identifier = "fac_main"
    results = Lakeraven::EHR::PatientSearch.call(name: "PERSON")
    assert_equal 0, results.length
  end

  test "PatientSearch returns all facilities when current facility is unset" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                          display_name: "OTHER,PERSON", date_of_birth: Date.new(1985, 12, 5), gender: "male")
    Lakeraven::EHR::Current.facility_identifier = nil
    results = Lakeraven::EHR::PatientSearch.call(name: "PERSON")
    assert_equal 1, results.length
  end

  test "PatientSearch raises MissingTenantContextError when tenant is unset" do
    Lakeraven::EHR::Current.tenant_identifier = nil
    assert_raises(Lakeraven::EHR::MissingTenantContextError) do
      Lakeraven::EHR::PatientSearch.call(name: "DOE")
    end
  end

  test "PatientSearch returns an empty array (not nil) for no matches" do
    result = Lakeraven::EHR::PatientSearch.call(name: "NONEXISTENT")
    assert_equal [], result
  end

  test "PatientSearch raises NotConfiguredError when adapter is missing" do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.tenant_identifier = "tnt_test"
    assert_raises(Lakeraven::EHR::NotConfiguredError) do
      Lakeraven::EHR::PatientSearch.call(name: "DOE")
    end
  end
end
