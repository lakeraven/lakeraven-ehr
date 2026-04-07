# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::Adapters::MockAdapterTest < ActiveSupport::TestCase
  Adapter = Lakeraven::EHR::Adapters::MockAdapter

  setup do
    @adapter = Adapter.new
  end

  test "inherits from Adapters::Base" do
    assert Adapter < Lakeraven::EHR::Adapters::Base
  end

  test "starts with no patients" do
    assert_empty @adapter.search_patients(tenant_identifier: "tnt_test")
  end

  test "seed_patient adds a patient and search returns it" do
    @adapter.seed_patient(
      tenant_identifier: "tnt_test",
      facility_identifier: "fac_main",
      display_name: "DOE,JOHN",
      date_of_birth: Date.new(1980, 1, 15),
      gender: "male"
    )
    results = @adapter.search_patients(tenant_identifier: "tnt_test", name: "DOE")
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:display_name]
  end

  test "seeded patient gets an opaque patient_identifier prefixed with pt_" do
    @adapter.seed_patient(
      tenant_identifier: "tnt_test",
      facility_identifier: "fac_main",
      display_name: "DOE,JOHN",
      date_of_birth: Date.new(1980, 1, 15),
      gender: "male"
    )
    result = @adapter.search_patients(tenant_identifier: "tnt_test", name: "DOE").first
    assert result[:patient_identifier].start_with?("pt_"), result[:patient_identifier]
  end

  test "search by name is case-insensitive partial match" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "JOHNSON,BOB", date_of_birth: Date.new(1990, 3, 10), gender: "male")
    results = @adapter.search_patients(tenant_identifier: "tnt_test", name: "joh")
    assert_equal 2, results.length
  end

  test "search is scoped to tenant" do
    @adapter.seed_patient(tenant_identifier: "tnt_a", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    @adapter.seed_patient(tenant_identifier: "tnt_b", facility_identifier: "fac_main",
                          display_name: "DOE,JANE", date_of_birth: Date.new(1981, 2, 16), gender: "female")
    results = @adapter.search_patients(tenant_identifier: "tnt_a", name: "DOE")
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:display_name]
  end

  test "search is scoped to facility when facility_identifier is given" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                          display_name: "OTHER,PERSON", date_of_birth: Date.new(1985, 12, 5), gender: "male")
    results = @adapter.search_patients(tenant_identifier: "tnt_test", facility_identifier: "fac_main")
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:display_name]
  end

  test "search returns all facilities in tenant when facility_identifier is nil" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                          display_name: "OTHER,PERSON", date_of_birth: Date.new(1985, 12, 5), gender: "male")
    results = @adapter.search_patients(tenant_identifier: "tnt_test")
    assert_equal 2, results.length
  end

  test "search results never expose backend-native dfn key" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    result = @adapter.search_patients(tenant_identifier: "tnt_test", name: "DOE").first
    refute_includes result.keys, :dfn
    refute_includes result.keys, "dfn"
  end

  test "find_patient resolves a previously-seeded patient by identifier" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    identifier = @adapter.search_patients(tenant_identifier: "tnt_test", name: "DOE").first[:patient_identifier]
    found = @adapter.find_patient(tenant_identifier: "tnt_test", patient_identifier: identifier)
    assert_equal "DOE,JOHN", found[:display_name]
  end

  test "find_patient returns nil for unknown identifier" do
    assert_nil @adapter.find_patient(tenant_identifier: "tnt_test", patient_identifier: "pt_unknown")
  end

  test "find_patient returns nil if identifier exists in a different tenant" do
    @adapter.seed_patient(tenant_identifier: "tnt_a", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    identifier = @adapter.search_patients(tenant_identifier: "tnt_a", name: "DOE").first[:patient_identifier]
    assert_nil @adapter.find_patient(tenant_identifier: "tnt_b", patient_identifier: identifier)
  end
end
