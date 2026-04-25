# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class PatientTest < ActiveSupport::TestCase
      # -- find_by_dfn -----------------------------------------------------------

      test "find_by_dfn returns a Patient for a known DFN" do
        patient = Patient.find_by_dfn(1)
        assert_not_nil patient
        assert_kind_of Patient, patient
        assert_equal 1, patient.dfn
        assert_equal "Anderson,Alice", patient.name
        assert_equal "F", patient.sex
      end

      test "find_by_dfn returns nil for unknown DFN" do
        assert_nil Patient.find_by_dfn(99_999)
      end

      test "find_by_dfn returns nil for zero" do
        assert_nil Patient.find_by_dfn(0)
      end

      test "find_by_dfn returns nil for nil" do
        assert_nil Patient.find_by_dfn(nil)
      end

      test "find_by_dfn merges extended demographics" do
        patient = Patient.find_by_dfn(1)
        assert_equal "AMERICAN INDIAN", patient.race
        assert_equal "123 Main St", patient.address_line1
        assert_equal "AK", patient.state
        assert_equal "907-555-1234", patient.phone
        assert_equal "ANLC-12345", patient.tribal_enrollment_number
      end

      # -- find (raises) --------------------------------------------------------

      test "find returns patient for known DFN" do
        patient = Patient.find(1)
        assert_equal 1, patient.dfn
      end

      test "find raises RecordNotFound for unknown DFN" do
        assert_raises(Patient::RecordNotFound) { Patient.find(99_999) }
      end

      # -- search ----------------------------------------------------------------

      test "search returns patients matching name pattern" do
        results = Patient.search("Anderson")
        assert_operator results.length, :>=, 1
        assert(results.all? { |p| p.is_a?(Patient) })
      end

      test "search returns empty array for no matches" do
        assert_equal [], Patient.search("ZZZZNONEXISTENT")
      end

      # -- search_by_ssn --------------------------------------------------------

      test "search_by_ssn returns array with matching patient" do
        results = Patient.search_by_ssn("111-11-1111")
        assert_equal 1, results.length
      end

      test "search_by_ssn returns empty array for no match" do
        assert_equal [], Patient.search_by_ssn("000-00-0000")
      end

      # -- composite fields: name ------------------------------------------------

      test "name syncs to first_name and last_name" do
        patient = Patient.new(name: "DOE,JOHN")
        assert_equal "Doe", patient.last_name
        assert_equal "John", patient.first_name
      end

      test "first_name and last_name sync to name" do
        patient = Patient.new(first_name: "Jane", last_name: "Smith")
        assert_equal "Smith,Jane", patient.name
      end

      # -- composite fields: born_on / dob ---------------------------------------

      test "born_on syncs to dob" do
        patient = Patient.new(born_on: Date.new(1980, 1, 15), sex: "M")
        assert_equal Date.new(1980, 1, 15), patient.dob
      end

      test "dob syncs to born_on" do
        patient = Patient.new(dob: Date.new(1990, 6, 1), sex: "F")
        assert_equal Date.new(1990, 6, 1), patient.born_on
      end

      # -- display_name ----------------------------------------------------------

      test "display_name formats MUMPS name for display" do
        patient = Patient.new(name: "DOE,JOHN")
        assert_equal "JOHN DOE", patient.display_name
      end

      test "formal_name capitalizes properly" do
        patient = Patient.new(name: "DOE,JOHN MICHAEL")
        assert_equal "Doe, John Michael", patient.formal_name
      end

      # -- persisted? ------------------------------------------------------------

      test "persisted? true with valid DFN" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        assert patient.persisted?
      end

      test "persisted? false without DFN" do
        patient = Patient.new(name: "DOE,JOHN", sex: "M")
        refute patient.persisted?
      end

      # -- PRC attributes -------------------------------------------------------

      test "patient has PRC-specific attributes" do
        patient = Patient.new(
          first_name: "John", last_name: "Doe",
          born_on: Date.new(1980, 1, 15),
          tribal_enrollment_number: "ANLC-12345",
          service_area: "Anchorage", coverage_type: "IHS"
        )
        assert_equal "ANLC-12345", patient.tribal_enrollment_number
        assert_equal "Anchorage", patient.service_area
        assert_equal "IHS", patient.coverage_type
      end

      # -- to_fhir ---------------------------------------------------------------

      test "to_fhir returns a FHIR Patient hash" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        assert_equal "Patient", fhir[:resourceType]
        assert_equal "1", fhir[:id]
        assert_includes fhir.dig(:meta, :profile), "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
        assert_equal "Anderson", fhir[:name].first[:family]
        assert_equal "female", fhir[:gender]
      end

      test "to_fhir includes RPMS identifiers" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        dfn_id = fhir[:identifier].find { |id| id[:system] == "urn:oid:2.16.840.1.113883.4.349" }
        assert_not_nil dfn_id
        assert_equal "1", dfn_id[:value]
      end

      test "to_fhir includes SSN identifier" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        ssn_id = fhir[:identifier].find { |id| id[:system]&.include?("ssn") }
        assert_equal "111-11-1111", ssn_id[:value]
      end

      test "to_fhir includes birthDate" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        assert_equal "1980-05-15", fhir[:birthDate]
      end

      test "to_fhir includes address" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        addr = fhir[:address]&.first
        assert_equal "AK", addr[:state]
        assert_equal "Anchorage", addr[:city]
      end

      test "to_fhir includes telecom" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        telecom = fhir[:telecom]&.first
        assert_equal "907-555-1234", telecom[:value]
      end

      test "to_fhir includes race extension" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        race_ext = fhir[:extension]&.find { |e| e[:url]&.include?("race") }
        assert_not_nil race_ext, "US Core requires race extension"
      end

      test "to_fhir gender maps F to female" do
        patient = Patient.new(dfn: 1, name: "DOE,JANE", sex: "F", dob: Date.new(1980, 1, 1))
        fhir = patient.to_fhir
        assert_equal "female", fhir[:gender]
      end

      test "to_fhir gender maps M to male" do
        patient = Patient.new(dfn: 2, name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 1))
        fhir = patient.to_fhir
        assert_equal "male", fhir[:gender]
      end

      test "to_fhir for minimal patient" do
        patient = Patient.new(dfn: 99, name: "MINIMAL,TEST", sex: "M")
        fhir = patient.to_fhir
        assert_equal "Patient", fhir[:resourceType]
        assert_equal "99", fhir[:id]
      end

      # -- clinical data accessors (ported from rpms_redux) ----------------------

      test "service_requests returns referrals for patient" do
        patient = Patient.find_by_dfn(1)
        referrals = patient.service_requests
        assert_kind_of Array, referrals
      end

      test "allergies returns allergy list for patient" do
        patient = Patient.find_by_dfn(1)
        allergies = patient.allergies
        assert_kind_of Array, allergies
      end

      test "problem_list returns conditions for patient" do
        patient = Patient.find_by_dfn(1)
        problems = patient.problem_list
        assert_kind_of Array, problems
      end

      test "medications returns medication requests for patient" do
        patient = Patient.find_by_dfn(1)
        meds = patient.medications
        assert_kind_of Array, meds
      end

      test "vitals returns observations for patient" do
        patient = Patient.find_by_dfn(1)
        vitals = patient.vitals
        assert_kind_of Array, vitals
      end

      # -- edge cases -----------------------------------------------------------

      test "name syncs handles three-part name" do
        patient = Patient.new(name: "DOE,JOHN MICHAEL JR")
        assert_equal "Doe", patient.last_name
        assert_equal "John michael jr", patient.first_name
      end

      test "display_name handles nil name" do
        patient = Patient.new(name: nil)
        assert_nil patient.display_name
      end

      test "formal_name handles nil name" do
        patient = Patient.new(name: nil)
        assert_nil patient.formal_name
      end

      test "age is stored from demographics" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", age: 45)
        assert_equal 45, patient.age
      end

      test "stores tribal_affiliation" do
        patient = Patient.new(tribal_affiliation: "Yup'ik")
        assert_equal "Yup'ik", patient.tribal_affiliation
      end

      test "stores birth_date alias" do
        patient = Patient.new(birth_date: Date.new(1980, 5, 15))
        assert_equal Date.new(1980, 5, 15), patient.birth_date
      end

      # -- tribal enrollment (ported from rpms_redux) ----------------------------

      test "validate_tribal_enrollment returns invalid when no enrollment number" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        result = patient.validate_tribal_enrollment
        refute result[:valid]
      end

      test "tribal_enrollment_valid? false without enrollment number" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        refute patient.tribal_enrollment_valid?
      end

      # -- from_fhir_attributes (ported from rpms_redux) -------------------------

      test "from_fhir_attributes parses FHIR resource" do
        fhir = OpenStruct.new(
          name: [ OpenStruct.new(family: "Parser", given: [ "Test", "Middle" ]) ],
          gender: "female",
          birthDate: "1990-05-15",
          identifier: [ OpenStruct.new(system: "http://hl7.org/fhir/sid/us-ssn", value: "555-55-5555") ]
        )
        attrs = Patient.from_fhir_attributes(fhir)
        assert_equal "Parser,Test Middle", attrs[:name]
        assert_equal "F", attrs[:sex]
        assert_equal Date.parse("1990-05-15"), attrs[:dob]
        assert_equal "555-55-5555", attrs[:ssn]
      end

      test "from_fhir_attributes handles missing name" do
        fhir = OpenStruct.new(name: [], gender: "male", birthDate: nil, identifier: [])
        attrs = Patient.from_fhir_attributes(fhir)
        assert_nil attrs[:name]
        assert_equal "M", attrs[:sex]
      end

      # -- FHIR US Core / TEFCA (ported from rpms_redux) -------------------------

      test "to_fhir includes tribal enrollment extension for TEFCA" do
        patient = Patient.new(dfn: 1, name: "TEST,TEFCA", sex: "M",
                              tribal_enrollment_number: "ANLC-12345")
        fhir = patient.to_fhir
        extensions = fhir[:extension] || []
        tribal_ext = extensions.find { |e| e[:url]&.include?("tribal") }
        assert tribal_ext, "TEFCA requires tribal enrollment extension"
      end

      test "to_fhir supports US Core Patient profile requirements" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        assert fhir[:identifier]&.any?, "US Core requires identifier"
        assert fhir[:name]&.any?, "US Core requires name"
        assert fhir[:gender].present?, "US Core requires gender"
        assert fhir[:birthDate].present?, "US Core requires birthDate"

        extensions = fhir[:extension] || []
        race_ext = extensions.find { |e| e[:url]&.include?("race") }
        assert race_ext, "US Core requires race extension"
      end

      test "to_fhir ready for QHIN exchange" do
        patient = Patient.find_by_dfn(1)
        fhir = patient.to_fhir

        assert_equal "Patient", fhir[:resourceType]
        assert fhir[:id].present?, "QHIN requires resource ID"
        assert fhir[:identifier]&.any?, "QHIN requires identifiers"
      end

      # -- providers association (ported from rpms_redux) ------------------------

      test "providers returns empty array when no service requests" do
        patient = Patient.new(dfn: 99999, name: "NOREFS,PATIENT", sex: "M")
        assert_equal [], patient.providers
      end
    end
  end
end
