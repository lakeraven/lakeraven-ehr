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

  # -- identifier filtering ---------------------------------------------------

  test "search by identifier_system + identifier_value matches FHIR Identifier" do
    @adapter.seed_patient(
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male",
      identifiers: [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "123-45-6789" } ]
    )
    @adapter.seed_patient(
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      display_name: "SMITH,JANE", date_of_birth: Date.new(1975, 6, 20), gender: "female",
      identifiers: [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "987-65-4321" } ]
    )
    results = @adapter.search_patients(
      tenant_identifier: "tnt_test",
      identifier_system: "http://hl7.org/fhir/sid/us-ssn",
      identifier_value: "123-45-6789"
    )
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:display_name]
  end

  test "search by identifier_system alone matches any value with that system" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "WITH,SSN", date_of_birth: Date.new(1980, 1, 1), gender: "male",
                          identifiers: [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111" } ])
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "WITHOUT,SSN", date_of_birth: Date.new(1981, 2, 2), gender: "female",
                          identifiers: [])
    results = @adapter.search_patients(
      tenant_identifier: "tnt_test",
      identifier_system: "http://hl7.org/fhir/sid/us-ssn"
    )
    assert_equal 1, results.length
    assert_equal "WITH,SSN", results.first[:display_name]
  end

  test "search by identifier returns nothing when value doesn't match" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male",
                          identifiers: [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "123-45-6789" } ])
    results = @adapter.search_patients(
      tenant_identifier: "tnt_test",
      identifier_system: "http://hl7.org/fhir/sid/us-ssn",
      identifier_value: "000-00-0000"
    )
    assert_empty results
  end

  test "patient with no identifiers seeded gets an empty identifiers array in results" do
    @adapter.seed_patient(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                          display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male")
    result = @adapter.search_patients(tenant_identifier: "tnt_test", name: "DOE").first
    assert_equal [], result[:identifiers]
  end

  test "attach_patient_identifier appends an identifier to an existing patient" do
    identifier = @adapter.seed_patient(
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      display_name: "DOE,JOHN", date_of_birth: Date.new(1980, 1, 15), gender: "male"
    )
    @adapter.attach_patient_identifier(
      tenant_identifier: "tnt_test",
      patient_identifier: identifier,
      system: "http://hl7.org/fhir/sid/us-ssn",
      value: "111-11-1111"
    )
    result = @adapter.find_patient(tenant_identifier: "tnt_test", patient_identifier: identifier)
    assert_equal [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111" } ], result[:identifiers]
  end

  # -- practitioners ----------------------------------------------------------

  test "starts with no practitioners" do
    assert_empty @adapter.search_practitioners(tenant_identifier: "tnt_test")
  end

  test "seed_practitioner adds a practitioner and search returns it" do
    @adapter.seed_practitioner(
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      display_name: "MARTINEZ,SARAH", specialty: "Cardiology"
    )
    results = @adapter.search_practitioners(tenant_identifier: "tnt_test", name: "MARTINEZ")
    assert_equal 1, results.length
    assert_equal "MARTINEZ,SARAH", results.first[:display_name]
    assert_equal "Cardiology", results.first[:specialty]
  end

  test "seeded practitioner gets an opaque practitioner_identifier prefixed with pr_" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    result = @adapter.search_practitioners(tenant_identifier: "tnt_test", name: "MARTINEZ").first
    assert result[:practitioner_identifier].start_with?("pr_"), result[:practitioner_identifier]
  end

  test "search_practitioners by name is case-insensitive partial match" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTIN,JANE", specialty: "Family Medicine")
    results = @adapter.search_practitioners(tenant_identifier: "tnt_test", name: "martin")
    assert_equal 2, results.length
  end

  test "search_practitioners by specialty matches case-insensitively" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "CHEN,JAMES", specialty: "Orthopedic Surgery")
    results = @adapter.search_practitioners(tenant_identifier: "tnt_test", specialty: "cardiology")
    assert_equal 1, results.length
    assert_equal "MARTINEZ,SARAH", results.first[:display_name]
  end

  test "search_practitioners by NPI identifier matches" do
    @adapter.seed_practitioner(
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      display_name: "MARTINEZ,SARAH", specialty: "Cardiology",
      identifiers: [ { system: "http://hl7.org/fhir/sid/us-npi", value: "1234567890" } ]
    )
    @adapter.seed_practitioner(
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      display_name: "CHEN,JAMES", specialty: "Orthopedic Surgery",
      identifiers: [ { system: "http://hl7.org/fhir/sid/us-npi", value: "2345678901" } ]
    )
    results = @adapter.search_practitioners(
      tenant_identifier: "tnt_test",
      identifier_system: "http://hl7.org/fhir/sid/us-npi",
      identifier_value: "2345678901"
    )
    assert_equal 1, results.length
    assert_equal "CHEN,JAMES", results.first[:display_name]
  end

  test "search_practitioners is scoped to tenant" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_a", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    @adapter.seed_practitioner(tenant_identifier: "tnt_b", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,JANE", specialty: "Cardiology")
    results = @adapter.search_practitioners(tenant_identifier: "tnt_a", name: "MARTINEZ")
    assert_equal 1, results.length
    assert_equal "MARTINEZ,SARAH", results.first[:display_name]
  end

  test "search_practitioners is scoped to facility when facility_identifier is given" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_other",
                               display_name: "OTHER,PROVIDER", specialty: "Dermatology")
    results = @adapter.search_practitioners(tenant_identifier: "tnt_test", facility_identifier: "fac_main")
    assert_equal 1, results.length
  end

  test "search_practitioners results never expose backend-native ien key" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    result = @adapter.search_practitioners(tenant_identifier: "tnt_test", name: "MARTINEZ").first
    refute_includes result.keys, :ien
    refute_includes result.keys, "ien"
    refute_includes result.keys, :IEN
    refute_includes result.keys, "IEN"
  end

  test "find_practitioner resolves a previously-seeded practitioner by identifier" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_test", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    identifier = @adapter.search_practitioners(tenant_identifier: "tnt_test", name: "MARTINEZ").first[:practitioner_identifier]
    found = @adapter.find_practitioner(tenant_identifier: "tnt_test", practitioner_identifier: identifier)
    assert_equal "MARTINEZ,SARAH", found[:display_name]
  end

  test "find_practitioner returns nil for unknown identifier" do
    assert_nil @adapter.find_practitioner(tenant_identifier: "tnt_test", practitioner_identifier: "pr_unknown")
  end

  test "find_practitioner returns nil if identifier exists in a different tenant" do
    @adapter.seed_practitioner(tenant_identifier: "tnt_a", facility_identifier: "fac_main",
                               display_name: "MARTINEZ,SARAH", specialty: "Cardiology")
    identifier = @adapter.search_practitioners(tenant_identifier: "tnt_a", name: "MARTINEZ").first[:practitioner_identifier]
    assert_nil @adapter.find_practitioner(tenant_identifier: "tnt_b", practitioner_identifier: identifier)
  end
end
