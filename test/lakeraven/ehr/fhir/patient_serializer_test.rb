# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::FHIR::PatientSerializerTest < ActiveSupport::TestCase
  Serializer = Lakeraven::EHR::FHIR::PatientSerializer
  US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"

  def base_record
    {
      patient_identifier: "pt_01H8X",
      facility_identifier: "fac_main",
      display_name: "DOE,JOHN",
      date_of_birth: Date.new(1980, 1, 15),
      gender: "male",
      identifiers: []
    }
  end

  test "renders resourceType Patient" do
    assert_equal "Patient", Serializer.call(base_record)[:resourceType]
  end

  test "id is the opaque patient_identifier" do
    assert_equal "pt_01H8X", Serializer.call(base_record)[:id]
  end

  test "meta.profile includes the US Core Patient profile" do
    assert_includes Serializer.call(base_record).dig(:meta, :profile), US_CORE_PROFILE
  end

  test "name parses display_name into family + given" do
    name = Serializer.call(base_record)[:name].first
    assert_equal "DOE", name[:family]
    assert_equal [ "JOHN" ], name[:given]
  end

  test "name handles a display_name with multiple given names" do
    record = base_record.merge(display_name: "DOE,JOHN MIDDLE")
    name = Serializer.call(record)[:name].first
    assert_equal "DOE", name[:family]
    assert_equal [ "JOHN", "MIDDLE" ], name[:given]
  end

  test "name falls back to a single text element when display_name has no comma" do
    record = base_record.merge(display_name: "MONONYM")
    name = Serializer.call(record)[:name].first
    assert_equal "MONONYM", name[:text]
    assert_nil name[:family]
  end

  test "gender passes through unchanged" do
    assert_equal "male", Serializer.call(base_record)[:gender]
  end

  test "gender returns 'unknown' for nil" do
    assert_equal "unknown", Serializer.call(base_record.merge(gender: nil))[:gender]
  end

  test "gender returns 'unknown' for an invalid value outside the FHIR code set" do
    # Locks in the normalization behavior — anything that isn't one of
    # male/female/other/unknown becomes "unknown" so the rendered
    # resource always validates against the administrative-gender
    # value set, regardless of what casing or junk the adapter passes.
    assert_equal "unknown", Serializer.call(base_record.merge(gender: "MALE"))[:gender]
    assert_equal "unknown", Serializer.call(base_record.merge(gender: "bogus"))[:gender]
  end

  test "birthDate is ISO8601 yyyy-mm-dd" do
    assert_equal "1980-01-15", Serializer.call(base_record)[:birthDate]
  end

  test "birthDate is omitted when date_of_birth is nil" do
    refute Serializer.call(base_record.merge(date_of_birth: nil)).key?(:birthDate)
  end

  test "identifiers round-trip with system and value" do
    record = base_record.merge(identifiers: [
      { system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111" }
    ])
    identifiers = Serializer.call(record)[:identifier]
    assert_equal "http://hl7.org/fhir/sid/us-ssn", identifiers.first[:system]
    assert_equal "111-11-1111", identifiers.first[:value]
  end

  test "identifier key is omitted when no identifiers seeded" do
    refute Serializer.call(base_record).key?(:identifier)
  end
end
