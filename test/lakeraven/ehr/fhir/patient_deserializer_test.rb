# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::FHIR::PatientDeserializerTest < ActiveSupport::TestCase
  Deserializer = Lakeraven::EHR::FHIR::PatientDeserializer

  def base_resource
    {
      resourceType: "Patient",
      name: [ { family: "DOE", given: [ "JOHN" ] } ],
      gender: "male",
      birthDate: "1980-01-15",
      identifier: [
        { system: "http://hl7.org/fhir/sid/us-ssn", value: "000-00-0000" }
      ]
    }
  end

  # ── Name extraction ──

  test "extracts name as VistA FAMILY,GIVEN format" do
    assert_equal "DOE,JOHN", Deserializer.call(base_resource)[:name]
  end

  test "joins multiple given names" do
    resource = base_resource.merge(name: [ { family: "DOE", given: [ "JOHN", "A" ] } ])
    assert_equal "DOE,JOHN A", Deserializer.call(resource)[:name]
  end

  test "prefers text field when present" do
    resource = base_resource.merge(name: [ { text: "DOE,JOHN A", family: "DOE", given: [ "JOHN" ] } ])
    assert_equal "DOE,JOHN A", Deserializer.call(resource)[:name]
  end

  test "returns family only when given is absent" do
    resource = base_resource.merge(name: [ { family: "DOE" } ])
    assert_equal "DOE", Deserializer.call(resource)[:name]
  end

  test "returns nil name when name array is missing" do
    resource = base_resource.except(:name)
    assert_nil Deserializer.call(resource)[:name]
  end

  test "returns nil name when name array is empty" do
    resource = base_resource.merge(name: [])
    assert_nil Deserializer.call(resource)[:name]
  end

  # ── Gender → sex mapping ──

  test "maps male to M" do
    assert_equal "M", Deserializer.call(base_resource)[:sex]
  end

  test "maps female to F" do
    resource = base_resource.merge(gender: "female")
    assert_equal "F", Deserializer.call(resource)[:sex]
  end

  test "maps unknown gender to U" do
    resource = base_resource.merge(gender: "unknown")
    assert_equal "U", Deserializer.call(resource)[:sex]
  end

  test "maps other gender to U" do
    resource = base_resource.merge(gender: "other")
    assert_equal "U", Deserializer.call(resource)[:sex]
  end

  test "maps nil gender to U" do
    resource = base_resource.except(:gender)
    assert_equal "U", Deserializer.call(resource)[:sex]
  end

  # ── Birth date ──

  test "parses birthDate as Date" do
    assert_equal Date.new(1980, 1, 15), Deserializer.call(base_resource)[:dob]
  end

  test "returns nil for missing birthDate" do
    resource = base_resource.except(:birthDate)
    assert_nil Deserializer.call(resource)[:dob]
  end

  test "returns nil for invalid birthDate" do
    resource = base_resource.merge(birthDate: "not-a-date")
    assert_nil Deserializer.call(resource)[:dob]
  end

  # ── SSN ──

  test "extracts SSN by system URI" do
    assert_equal "000-00-0000", Deserializer.call(base_resource)[:ssn]
  end

  test "returns nil SSN when no identifiers present" do
    resource = base_resource.except(:identifier)
    assert_nil Deserializer.call(resource)[:ssn]
  end

  test "returns nil SSN when no SSN identifier in array" do
    resource = base_resource.merge(identifier: [
      { system: "http://example.com/mrn", value: "12345" }
    ])
    assert_nil Deserializer.call(resource)[:ssn]
  end

  # ── String-keyed hashes ──

  test "works with string-keyed hash" do
    resource = {
      "resourceType" => "Patient",
      "name" => [ { "family" => "DOE", "given" => [ "JOHN" ] } ],
      "gender" => "female",
      "birthDate" => "1990-06-01"
    }
    result = Deserializer.call(resource)
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "F", result[:sex]
    assert_equal Date.new(1990, 6, 1), result[:dob]
  end

  # ── Dot-access objects ──

  test "works with OpenStruct-style objects" do
    NameEntry = Struct.new(:family, :given, :text, keyword_init: true) unless defined?(NameEntry)
    FhirPatient = Struct.new(:name, :gender, :birthDate, :identifier, keyword_init: true) unless defined?(FhirPatient)

    name_obj = NameEntry.new(family: "DOE", given: [ "JANE" ], text: nil)
    resource = FhirPatient.new(
      name: [ name_obj ],
      gender: "female",
      birthDate: "1990-06-01",
      identifier: nil
    )
    result = Deserializer.call(resource)
    assert_equal "DOE,JANE", result[:name]
    assert_equal "F", result[:sex]
  end
end
