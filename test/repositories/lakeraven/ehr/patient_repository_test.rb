# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientRepositoryTest < ActiveSupport::TestCase
      # =============================================================================
      # FIND
      # =============================================================================

      test "find returns Patient for known DFN" do
        patient = PatientRepository.find(1)

        assert_instance_of Patient, patient
        assert_equal 1, patient.dfn
        assert_equal "Anderson,Alice", patient.name
      end

      test "find returns nil for unknown DFN" do
        assert_nil PatientRepository.find(99999)
      end

      test "find returns nil for blank DFN" do
        assert_nil PatientRepository.find(nil)
        assert_nil PatientRepository.find("")
      end

      test "find merges extended demographics" do
        patient = PatientRepository.find(1)

        assert_equal "AMERICAN INDIAN", patient.race
        assert_equal "123 Main St", patient.address_line1
        assert_equal "Anchorage", patient.city
      end

      test "find includes tribal enrollment data" do
        patient = PatientRepository.find(1)

        assert_equal "ANLC-12345", patient.tribal_enrollment_number
        assert_equal "Anchorage", patient.service_area
      end

      # =============================================================================
      # FIND WITH PROVENANCE
      # =============================================================================

      test "find attaches provenance metadata" do
        patient = PatientRepository.find(1)

        refute_nil patient.provenance
        assert_equal :rpc, patient.provenance[:rpms][:source]
        refute_nil patient.provenance[:rpms][:fetched_at]
      end

      # =============================================================================
      # SEARCH
      # =============================================================================

      test "search returns array of patients" do
        patients = PatientRepository.search("Anderson")

        assert patients.is_a?(Array)
        assert patients.any?
        assert patients.all? { |p| p.is_a?(Patient) }
      end

      test "search returns empty array for no matches" do
        patients = PatientRepository.search("ZZZZZ")

        assert_equal [], patients
      end

      # =============================================================================
      # FIND BY SSN
      # =============================================================================

      test "find_by_ssn returns patient" do
        patient = PatientRepository.find_by_ssn("111-11-1111")

        refute_nil patient
        assert_instance_of Patient, patient
      end

      test "find_by_ssn returns nil for unknown SSN" do
        assert_nil PatientRepository.find_by_ssn("000-00-0000")
      end

      # =============================================================================
      # IMMUTABILITY
      # =============================================================================

      test "returned patient has provenance" do
        patient = PatientRepository.find(1)

        refute_nil patient.provenance
        assert_equal :rpc, patient.provenance[:rpms][:source]
      end

      # =============================================================================
      # MODEL DELEGATION
      # =============================================================================

      test "Patient.find delegates to repository" do
        patient = Patient.find(1)

        assert_instance_of Patient, patient
        assert_equal 1, patient.dfn
      end

      test "Patient.search delegates to repository" do
        patients = Patient.search("Anderson")

        assert patients.any?
      end

      test "Patient.find_by_dfn delegates to repository" do
        patient = Patient.find_by_dfn(1)

        refute_nil patient
        assert_equal 1, patient.dfn
      end
    end
  end
end
