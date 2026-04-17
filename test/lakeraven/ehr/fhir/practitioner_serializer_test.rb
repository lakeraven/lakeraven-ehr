# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::FHIR::PractitionerSerializerTest < ActiveSupport::TestCase
  Serializer = Lakeraven::EHR::FHIR::PractitionerSerializer
  US_CORE_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-practitioner"

  def base_record
    {
      practitioner_identifier: "prov_01H8X",
      display_name: "DOE,JOHN",
      npi: "1234567890",
      identifiers: []
    }
  end

  test "renders resourceType Practitioner" do
    assert_equal "Practitioner", Serializer.call(base_record)[:resourceType]
  end

  test "id is the opaque practitioner_identifier" do
    assert_equal "prov_01H8X", Serializer.call(base_record)[:id]
  end

  test "meta.profile includes the US Core Practitioner profile" do
    assert_includes Serializer.call(base_record).dig(:meta, :profile), US_CORE_PROFILE
  end

  test "name parses display_name into family + given" do
    name = Serializer.call(base_record)[:name].first
    assert_equal "DOE", name[:family]
    assert_equal [ "JOHN" ], name[:given]
  end

  test "name handles multiple given names" do
    record = base_record.merge(display_name: "DOE,JOHN MIDDLE")
    name = Serializer.call(record)[:name].first
    assert_equal [ "JOHN", "MIDDLE" ], name[:given]
  end

  test "name falls back to text when no comma" do
    record = base_record.merge(display_name: "ADMIN")
    name = Serializer.call(record)[:name].first
    assert_equal "ADMIN", name[:text]
    assert_nil name[:family]
  end

  test "gender maps M to male" do
    assert_equal "male", Serializer.call(base_record.merge(gender: "M"))[:gender]
  end

  test "gender maps F to female" do
    assert_equal "female", Serializer.call(base_record.merge(gender: "F"))[:gender]
  end

  test "gender is nil when not provided" do
    assert_nil Serializer.call(base_record)[:gender]
  end

  test "NPI identifier included with official use" do
    ids = Serializer.call(base_record)[:identifier]
    npi = ids.find { |i| i[:system] == "http://hl7.org/fhir/sid/us-npi" }
    assert_equal "1234567890", npi[:value]
    assert_equal "official", npi[:use]
  end

  test "DEA identifier included when present" do
    record = base_record.merge(dea_number: "AB1234567")
    ids = Serializer.call(record)[:identifier]
    dea = ids.find { |i| i[:system] == "http://hl7.org/fhir/sid/us-dea" }
    assert_equal "AB1234567", dea[:value]
  end

  test "IEN identifier included when present" do
    record = base_record.merge(ien: 42)
    ids = Serializer.call(record)[:identifier]
    ien = ids.find { |i| i[:system] == "http://ihs.gov/rpms/provider-id" }
    assert_equal "42", ien[:value]
  end

  test "identifier key omitted when no identifiers" do
    record = base_record.merge(npi: nil)
    refute Serializer.call(record).key?(:identifier)
  end

  test "specialty emitted as qualification" do
    record = base_record.merge(specialty: "Family Medicine")
    quals = Serializer.call(record)[:qualification]
    assert_equal "Family Medicine", quals.first.dig(:code, :text)
  end

  test "provider_class emitted as qualification" do
    record = base_record.merge(provider_class: "Physician")
    quals = Serializer.call(record)[:qualification]
    assert_equal "Physician", quals.first.dig(:code, :text)
  end

  test "qualification key omitted when no specialty or provider_class" do
    refute Serializer.call(base_record).key?(:qualification)
  end

  test "telecom included when phone present" do
    record = base_record.merge(phone: "555-0100")
    telecom = Serializer.call(record)[:telecom].first
    assert_equal "phone", telecom[:system]
    assert_equal "555-0100", telecom[:value]
    assert_equal "work", telecom[:use]
  end

  test "telecom key omitted when phone blank" do
    refute Serializer.call(base_record).key?(:telecom)
  end
end
