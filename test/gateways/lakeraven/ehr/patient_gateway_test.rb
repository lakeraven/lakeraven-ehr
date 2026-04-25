# frozen_string_literal: true

require "test_helper"

# Tests for PatientGateway — the repository layer that owns
# all RPMS RPC details for patient demographics.
# Uses mock data seeded in test_helper.rb via RpmsRpc.mock!
module Lakeraven
  module EHR
    class PatientGatewayTest < ActiveSupport::TestCase
      # === find ===

      test "find returns patient by DFN" do
        patient = PatientGateway.find(1)

        assert_not_nil patient, "Should find patient"
        assert_instance_of Patient, patient
        assert_equal 1, patient.dfn
        assert_equal "Anderson,Alice", patient.name
        assert_equal "F", patient.sex
        assert_equal Date.parse("1980-05-15"), patient.dob
        assert_equal 45, patient.age
      end

      test "find merges extended demographics from patient_id_info" do
        patient = PatientGateway.find(1)

        assert_equal "AMERICAN INDIAN", patient.race
        assert_equal "123 Main St", patient.address_line1
        assert_equal "Anchorage", patient.city
        assert_equal "AK", patient.state
        assert_equal "99501", patient.zip_code
        assert_equal "907-555-1234", patient.phone
        assert_equal "ANLC-12345", patient.tribal_enrollment_number
        assert_equal "Anchorage", patient.service_area
        assert_equal "IHS", patient.coverage_type
      end

      test "find returns nil for invalid DFN" do
        patient = PatientGateway.find(999999)

        assert_nil patient, "Should return nil for non-existent patient"
      end

      test "find returns patient without extended demographics when unavailable" do
        patient = PatientGateway.find(2)

        assert_not_nil patient
        assert_equal "MOUSE,MICKEY M", patient.name
        assert_equal "M", patient.sex
        # Extended fields come from patient_id_info seed for DFN 2
        assert_equal "AMERICAN INDIAN", patient.race
      end

      # === search ===

      test "search returns patients matching name" do
        patients = PatientGateway.search("A")

        assert patients.is_a?(Array), "Should return array"
        assert patients.length >= 1, "Should find at least one match"

        patients.each do |patient|
          assert_instance_of Patient, patient
          assert patient.dfn.positive?, "Patient should have valid DFN"
          assert patient.name.present?, "Patient should have name"
        end
      end

      test "search returns empty array when no matches" do
        patients = PatientGateway.search("ZZZZNONEXISTENT")

        assert patients.is_a?(Array), "Should return array"
        assert_equal 0, patients.length, "Should return empty array for no matches"
      end

      test "search returns all patients for broad match" do
        patients = PatientGateway.search("")

        assert_equal 3, patients.length, "Should return all seeded patients"
      end

      # === find_by_ssn ===

      test "find_by_ssn returns patient matching SSN" do
        patient = PatientGateway.find_by_ssn("111-11-1111")

        assert_not_nil patient, "Should find patient by SSN"
        assert_instance_of Patient, patient
        assert_equal 1, patient.dfn
      end

      test "find_by_ssn returns nil for unknown SSN" do
        patient = PatientGateway.find_by_ssn("999-99-9999")

        assert_nil patient, "Should return nil for unknown SSN"
      end

      # === FHIR compatibility ===

      test "patient from gateway has FHIR-compatible attributes" do
        patient = PatientGateway.find(1)

        assert patient.respond_to?(:dfn), "Should have dfn"
        assert patient.respond_to?(:name), "Should have name"
        assert patient.respond_to?(:sex), "Should have sex"
        assert patient.respond_to?(:dob), "Should have dob"
        assert patient.respond_to?(:phone), "Should have phone"
        assert patient.respond_to?(:to_fhir), "Should be FHIR serializable"
      end

      test "patient from gateway is persisted" do
        patient = PatientGateway.find(1)

        assert patient.persisted?, "Patient with DFN should be persisted"
      end

      test "patient from gateway has synced composite fields" do
        patient = PatientGateway.find(1)

        assert_equal patient.dob, patient.born_on, "born_on should sync with dob"
        assert patient.first_name.present?, "Should derive first_name from name"
        assert patient.last_name.present?, "Should derive last_name from name"
      end
    end
  end
end
