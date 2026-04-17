# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::FHIR::PractitionerDeserializerTest < ActiveSupport::TestCase
  Deserializer = Lakeraven::EHR::FHIR::PractitionerDeserializer

  def base_resource
    {
      resourceType: "Practitioner",
      name: [ { family: "DOE", given: [ "JOHN" ] } ],
      gender: "male",
      identifier: [
        { system: "http://hl7.org/fhir/sid/us-npi", value: "1234567890" },
        { system: "http://hl7.org/fhir/sid/us-dea", value: "AB1234567" }
      ],
      qualification: [
        { code: { text: "Family Medicine" } }
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

  test "returns nil name when name array is missing" do
    resource = base_resource.except(:name)
    assert_nil Deserializer.call(resource)[:name]
  end

  # ── NPI ──

  test "extracts NPI by system URI" do
    assert_equal "1234567890", Deserializer.call(base_resource)[:npi]
  end

  test "returns nil NPI when no identifiers" do
    resource = base_resource.except(:identifier)
    assert_nil Deserializer.call(resource)[:npi]
  end

  test "returns nil NPI when no NPI identifier in array" do
    resource = base_resource.merge(identifier: [
      { system: "http://example.com/mrn", value: "12345" }
    ])
    assert_nil Deserializer.call(resource)[:npi]
  end

  # ── DEA ──

  test "extracts DEA number by system URI" do
    assert_equal "AB1234567", Deserializer.call(base_resource)[:dea_number]
  end

  # ── Gender mapping ──

  test "maps male to M" do
    assert_equal "M", Deserializer.call(base_resource)[:gender]
  end

  test "maps female to F" do
    resource = base_resource.merge(gender: "female")
    assert_equal "F", Deserializer.call(resource)[:gender]
  end

  test "returns nil gender for missing gender" do
    resource = base_resource.except(:gender)
    assert_nil Deserializer.call(resource)[:gender]
  end

  test "returns nil gender for unknown values" do
    resource = base_resource.merge(gender: "other")
    assert_nil Deserializer.call(resource)[:gender]
  end

  # ── Specialty ──

  test "extracts specialty from first qualification" do
    assert_equal "Family Medicine", Deserializer.call(base_resource)[:specialty]
  end

  test "returns nil specialty when no qualifications" do
    resource = base_resource.except(:qualification)
    assert_nil Deserializer.call(resource)[:specialty]
  end

  # ── String-keyed hashes ──

  test "works with string-keyed hash" do
    resource = {
      "resourceType" => "Practitioner",
      "name" => [ { "family" => "DOE", "given" => [ "JOHN" ] } ],
      "gender" => "female",
      "identifier" => [
        { "system" => "http://hl7.org/fhir/sid/us-npi", "value" => "9876543210" }
      ]
    }
    result = Deserializer.call(resource)
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "F", result[:gender]
    assert_equal "9876543210", result[:npi]
  end
end
