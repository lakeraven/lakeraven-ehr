# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class PatientFhirTest < ActiveSupport::TestCase
      # =============================================================================
      # FHIR Serialization — detailed output tests (ported from rpms_redux)
      # =============================================================================

      test "to_fhir serializes patient correctly" do
        patient = Patient.new(
          dfn: 123, name: "SMITH,JOHN", sex: "M",
          dob: Date.new(1980, 1, 1), ssn: "123-45-6789",
          phone: "555-123-4567", address_line1: "123 Main St",
          city: "Phoenix", state: "AZ", zip_code: "85001"
        )

        fhir = patient.to_fhir

        assert_equal "Patient", fhir[:resourceType]
        assert_equal "123", fhir[:id]
        assert_equal "SMITH", fhir[:name].first[:family]
        assert_equal "male", fhir[:gender]
        assert_equal "1980-01-01", fhir[:birthDate]
      end

      test "to_fhir creates identifier with DFN" do
        patient = Patient.new(dfn: 456, name: "DOE,JANE", sex: "F")
        fhir = patient.to_fhir

        identifier = fhir[:identifier].find { |id| id[:system] == "urn:oid:2.16.840.1.113883.4.349" }
        assert_not_nil identifier
        assert_equal "456", identifier[:value]
      end

      test "to_fhir creates SSN identifier when present" do
        patient = Patient.new(dfn: 123, name: "SMITH,JOHN", ssn: "123-45-6789")
        fhir = patient.to_fhir

        ssn_identifier = fhir[:identifier].find { |id| id[:system] == "http://hl7.org/fhir/sid/us-ssn" }
        assert_not_nil ssn_identifier
        assert_equal "123-45-6789", ssn_identifier[:value]
      end

      test "to_fhir maps gender correctly" do
        { "M" => "male", "F" => "female", "U" => "unknown", nil => "unknown" }.each do |sex, expected|
          patient = Patient.new(dfn: 1, name: "TEST,PATIENT", sex: sex)
          fhir = patient.to_fhir
          assert_equal expected, fhir[:gender],
                       "Sex #{sex.inspect} should map to FHIR #{expected}"
        end
      end

      test "to_fhir includes address when present" do
        patient = Patient.new(
          dfn: 123, name: "SMITH,JOHN",
          address_line1: "123 Main St", city: "Phoenix", state: "AZ", zip_code: "85001"
        )
        fhir = patient.to_fhir

        assert_equal 1, fhir[:address].length
        address = fhir[:address].first
        assert_equal "123 Main St", address[:line].first
        assert_equal "Phoenix", address[:city]
        assert_equal "AZ", address[:state]
        assert_equal "85001", address[:postalCode]
      end

      test "to_fhir includes telecom when phone present" do
        patient = Patient.new(dfn: 123, name: "SMITH,JOHN", phone: "555-123-4567")
        fhir = patient.to_fhir

        phone = fhir[:telecom].find { |t| t[:system] == "phone" }
        assert_not_nil phone
        assert_equal "555-123-4567", phone[:value]
      end

      test "to_fhir handles missing optional fields" do
        patient = Patient.new(dfn: 123, name: "SMITH,JOHN", sex: "M")
        fhir = patient.to_fhir

        assert_not_nil fhir
        assert_equal "123", fhir[:id]
        assert_equal "SMITH", fhir[:name].first[:family]
      end

      # =============================================================================
      # from_fhir_attributes — round-trip tests (ported from rpms_redux)
      # =============================================================================

      test "from_fhir_attributes maps FHIR gender to VistA" do
        { "male" => "M", "female" => "F", "other" => "U", "unknown" => "U" }.each do |fhir_gender, sex|
          fhir = ::OpenStruct.new(
            name: [ ::OpenStruct.new(text: "TEST") ],
            gender: fhir_gender,
            birthDate: nil,
            identifier: []
          )
          attrs = Patient.from_fhir_attributes(fhir)
          assert_equal sex, attrs[:sex],
                       "FHIR gender #{fhir_gender} should map to #{sex}"
        end
      end

      test "round-trip FHIR serialization preserves core data" do
        original = Patient.new(
          dfn: 123, name: "SMITH,JOHN", sex: "M",
          dob: Date.new(1980, 1, 1), ssn: "123-45-6789"
        )

        fhir_hash = original.to_fhir

        # Build an ::OpenStruct resembling a FHIR resource for from_fhir_attributes
        fhir_resource = ::OpenStruct.new(
          name: [ ::OpenStruct.new(family: fhir_hash[:name].first[:family],
                                given: fhir_hash[:name].first[:given],
                                text: nil) ],
          gender: fhir_hash[:gender],
          birthDate: fhir_hash[:birthDate],
          identifier: fhir_hash[:identifier].map { |id| ::OpenStruct.new(id) }
        )

        round_trip = Patient.new(Patient.from_fhir_attributes(fhir_resource))

        assert_equal "SMITH,JOHN", round_trip.name
        assert_equal "M", round_trip.sex
        assert_equal Date.new(1980, 1, 1), round_trip.dob
        assert_equal "123-45-6789", round_trip.ssn
      end
    end
  end
end
