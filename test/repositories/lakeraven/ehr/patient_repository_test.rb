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

      test "find merges identifier fields from patient_id_info" do
        # ORWPT ID INFO contributes race_code + site_ien on top of
        # patient_select. The long-form :race string, address, city,
        # service_area and coverage_type still have NO known RPC source — the
        # old BHDPTRPC attribution was unverified (see rpms-rpc
        # docs/RPC_COVERAGE.md, "BHDPTRPC provenance").
        patient = PatientRepository.find(1)

        assert_equal "I", patient.race_code
        assert_equal 7819, patient.site_ien
        assert_nil patient.race
        assert_nil patient.address_line1
      end

      # tribal_enrollment_number is NO LONGER in the unsourced set. RPMS stores
      # it in #9000001 (^AUPNPAT) field .07 and the repository now reads it via
      # DDR GETS ENTRY DATA, so `find` populates it and the tribe name. This
      # test previously asserted it was nil, which pinned the absence of a read
      # path rather than a property of the data.
      test "find attaches tribal detail read from #9000001" do
        patient = PatientRepository.find(1)

        assert_equal "EXNH-12345", patient.tribal_enrollment_number
        assert_equal "Example Tribe", patient.tribal_affiliation
      end

      # The tribal read is a SECOND broker round trip, so it must not run once
      # per row of a result set. `search` goes through attach_provenance, not
      # build_patient, which is what keeps it off that path.
      test "search does not attach tribal detail per row" do
        results = PatientRepository.search("Anderson")

        refute_empty results
        assert_nil results.first.tribal_enrollment_number
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
      # SOURCE PREFERENCE
      # =============================================================================

      test "find defaults to rpc_only source" do
        patient = PatientRepository.find(1)

        assert_equal :rpc, patient.provenance[:rpms][:source]
      end

      test "find accepts source_preference rpc_only" do
        patient = PatientRepository.find(1, source_preference: :rpc_only)

        refute_nil patient
        assert_equal :rpc, patient.provenance[:rpms][:source]
      end

      test "find accepts source_preference fhir_first" do
        patient = PatientRepository.find(1, source_preference: :fhir_first)

        refute_nil patient
        # Falls back to RPC when FHIR client not configured
        assert_includes [ :rpc, :fhir ], patient.provenance[:rpms][:source]
      end

      test "search accepts source_preference" do
        patients = PatientRepository.search("Anderson", source_preference: :rpc_only)

        assert patients.any?
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
