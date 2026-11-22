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

      test "find does not read a race code or site from ORWPT ID INFO" do
        # ORWPT ID INFO contributes race_code + site_ien on top of
        # patient_select. The long-form :race string, address, city,
        # service_area and coverage_type still have NO known RPC source — the
        # old BHDPTRPC attribution was unverified (see rpms-rpc
        # docs/RPC_COVERAGE.md, "BHDPTRPC provenance").
        patient = PatientRepository.find(1)

        # ORWPT ID INFO pieces 4 and 6 are the VETERAN flag and the ward (rpms-rpc #309), not a race code and a site.
        assert_nil patient.race_code
        assert_nil patient.site_ien
        assert_nil patient.race
        assert_nil patient.address_line1
        # Both halves of the reverted enrichment are pinned, not just the tribal
        # one (gate findings on #563, see #566). Nothing populates either until
        # the reads are rebuilt: tribal needs an authorization gate on a
        # sovereign identifier and a reachable rescue; telecom needs a gem lock
        # that actually contains RpmsRpc::Patient.contact -- the lock pins
        # f514068 (21 Sep) and the method arrived in 19fffc3 (24 Sep), so it
        # raised NoMethodError in every deployed build and the rescue hid it.
        assert_nil patient.tribal_enrollment_number
        assert_nil patient.tribal_affiliation
        assert_nil patient.phone
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

      # =============================================================================
      # FHIR READ PATH: the engine's own client (#599)
      # =============================================================================

      test "configuration fhir_client defaults to nil" do
        assert_nil Lakeraven::EHR::Configuration.new.fhir_client
      end

      test "fhir_first reads the patient from the configured FHIR client" do
        with_fhir_client(seeded_fhir_client("1")) do
          patient = PatientRepository.find(1, source_preference: :fhir_first)

          assert_instance_of Patient, patient
          assert_equal :fhir, patient.provenance[:rpms][:source]
          assert_equal 1, patient.dfn
          assert_equal "TESTPATIENT,ADA", patient.name
          assert_equal "F", patient.sex
          assert_equal Date.new(1980, 5, 15), patient.dob
        end
      end

      test "fhir_first falls back to RPC when the FHIR client has no such patient" do
        with_fhir_client(Lakeraven::EHR::FHIR::MockClient.new) do
          patient = PatientRepository.find(1, source_preference: :fhir_first)

          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "fhir_first reads from RPC when no FHIR client is configured" do
        with_fhir_client(nil) do
          patient = PatientRepository.find(1, source_preference: :fhir_first)

          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "fhir_first returns nil when neither source knows the patient" do
        with_fhir_client(Lakeraven::EHR::FHIR::MockClient.new) do
          assert_nil PatientRepository.find(99999, source_preference: :fhir_first)
        end
      end

      test "rpc_first returns the FHIR patient when RPC does not know the DFN" do
        with_fhir_client(seeded_fhir_client("99999")) do
          patient = PatientRepository.find(99999, source_preference: :rpc_first)

          assert_instance_of Patient, patient
          assert_equal :fhir, patient.provenance[:rpms][:source]
          assert_equal 99999, patient.dfn
          assert_equal "TESTPATIENT,ADA", patient.name
        end
      end

      test "rpc_first returns the RPC patient when RPC knows the DFN" do
        with_fhir_client(seeded_fhir_client("1")) do
          patient = PatientRepository.find(1, source_preference: :rpc_first)

          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "rpc_only never reads the configured FHIR client" do
        with_fhir_client(seeded_fhir_client("1")) do
          patient = PatientRepository.find(1, source_preference: :rpc_only)

          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "fhir_first falls back to RPC when the FHIR client raises" do
        failing = Object.new
        failing.define_singleton_method(:read) do |_type, _id|
          raise Lakeraven::EHR::FHIR::Client::Error, "FHIR endpoint answered 503"
        end

        with_fhir_client(failing) do
          patient = PatientRepository.find(1, source_preference: :fhir_first)

          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "the FHIR read path never touches RpmsRpc's FHIR surface" do
        StubHelpers.with_recording_stub(RpmsRpc, :fhir_client, nil) do |client_calls|
          StubHelpers.with_recording_stub(RpmsRpc, :mock_fhir!, nil) do |mock_calls|
            fhir_first = PatientRepository.find(1, source_preference: :fhir_first)
            rpc_first = PatientRepository.find(99999, source_preference: :rpc_first)

            assert_empty client_calls, "PatientRepository called RpmsRpc.fhir_client"
            assert_empty mock_calls, "PatientRepository called RpmsRpc.mock_fhir!"
            assert_equal :rpc, fhir_first.provenance[:rpms][:source]
            assert_nil rpc_first
          end
        end
      end

      test "nothing in the engine names the rpms-rpc FHIR client" do
        root = Lakeraven::EHR::Engine.root
        banned = [ "RpmsRpc.fhir_client", "RpmsRpc.mock_fhir!", "RpmsRpc::MockFhirClient", "RpmsRpc::FhirClient" ]
        this_file = File.expand_path(__FILE__)

        offenders = %w[app lib test].flat_map do |dir|
          Dir.glob(root.join(dir, "**", "*").to_s).select { |path| File.file?(path) }
        end.reject { |path| File.expand_path(path) == this_file || path.include?("/test/dummy/tmp/") || path.include?("/test/dummy/log/") }
          .filter_map do |path|
            text = File.binread(path)
            hits = banned.select { |needle| text.include?(needle) }
            "#{path.delete_prefix("#{root}/")}: #{hits.join(', ')}" if hits.any?
          end

        assert_empty offenders, "rpms-rpc FHIR client still referenced:\n#{offenders.join("\n")}"
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

      private

      # Sets the engine's FHIR client for the block and puts the previous one
      # back afterwards. Only this one attribute is saved and restored, so the
      # rest of the configuration is left alone.
      def with_fhir_client(client)
        config = Lakeraven::EHR.configuration
        saved = config.fhir_client
        config.fhir_client = client
        yield
      ensure
        config.fhir_client = saved if config.respond_to?(:fhir_client=)
      end

      # Synthetic patient, seeded under the given id.
      def seeded_fhir_client(id)
        client = Lakeraven::EHR::FHIR::MockClient.new
        client.seed_resource("Patient", id, {
          resourceType: "Patient", id: id,
          name: [ { family: "Testpatient", given: [ "Ada" ] } ],
          gender: "female", birthDate: "1980-05-15"
        })
        client
      end
    end
  end
end
