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
        fhir = seeded_fhir_client("1")
        fhir.seed_resource("Patient", "99999", synthetic_patient("99999"))

        StubHelpers.with_recording_stub(RpmsRpc, :fhir_client, nil) do |client_calls|
          StubHelpers.with_recording_stub(RpmsRpc, :mock_fhir!, nil) do |mock_calls|
            with_fhir_client(fhir) do
              fhir_first = PatientRepository.find(1, source_preference: :fhir_first)
              rpc_first = PatientRepository.find(99999, source_preference: :rpc_first)

              assert_empty client_calls, "PatientRepository called RpmsRpc.fhir_client"
              assert_empty mock_calls, "PatientRepository called RpmsRpc.mock_fhir!"
              assert_equal :fhir, fhir_first.provenance[:rpms][:source]
              assert_equal "TESTPATIENT,ADA", fhir_first.name
              assert_equal :fhir, rpc_first.provenance[:rpms][:source]
              assert_equal 99999, rpc_first.dfn
            end
          end
        end
      end

      # --- one rule for a FHIR read (#599 review round 2) ---
      #
      # A FHIR read for a DFN ends one of three ways:
      #   PATIENT  a Patient whose id is exactly the DFN, that Patient.from_fhir
      #            maps, and whose mapped name is present.
      #   ABSENT   a not-found OperationOutcome, or no FHIR client configured.
      #   FAILURE  everything else.
      # :fhir_first reads RPC after ABSENT or FAILURE; when RPC has no patient
      # either, ABSENT is nil and FAILURE raises Client::Error, because we
      # could not tell whether the patient exists. :rpc_first asks FHIR only
      # when RPC has no patient: ABSENT is nil, FAILURE raises.
      #
      # Factory-Spec-Amendment (#599 review round 2): the rpc_first examples
      # below used to expect nil for a wrong answer about DFN 99999. A wrong
      # answer is a FAILURE, not a miss, so they now expect Client::Error.
      CLIENT_ERROR = Lakeraven::EHR::FHIR::Client::Error

      # Each answer is given for the DFN that was asked. None of them is that
      # patient, so none may come back as a Patient with source :fhir.
      WRONG_ANSWERS = {
        "a Patient with another id" => ->(_dfn) { { "resourceType" => "Patient", "id" => "424242", "name" => [ { "family" => "Wrongpatient", "given" => [ "Bea" ] } ] } },
        "a Patient with no id" => ->(_dfn) { { "resourceType" => "Patient", "name" => [ { "family" => "Wrongpatient", "given" => [ "Bea" ] } ] } },
        "a Patient whose id only starts with the DFN" => ->(dfn) { { "resourceType" => "Patient", "id" => "#{dfn}abc", "name" => [ { "family" => "Wrongpatient", "given" => [ "Bea" ] } ] } },
        "an empty object" => ->(_dfn) { {} },
        "an empty searchset Bundle" => ->(_dfn) { { "resourceType" => "Bundle", "type" => "searchset", "total" => 0, "entry" => [] } },
        "a Practitioner with the DFN as its id" => ->(dfn) { { "resourceType" => "Practitioner", "id" => dfn.to_s, "name" => [ { "family" => "Wrongprovider", "given" => [ "Cy" ] } ] } },
        "an OperationOutcome that is not not-found" => ->(_dfn) { { "resourceType" => "OperationOutcome", "issue" => [ { "severity" => "error", "code" => "processing", "diagnostics" => "Bodymarker" } ] } },
        "an OperationOutcome with no issues" => ->(_dfn) { { "resourceType" => "OperationOutcome", "issue" => [] } },
        "nil" => ->(_dfn) { nil }
      }.freeze

      # The requested Patient, with nothing Patient.from_fhir maps to a name.
      NAMELESS_ANSWERS = {
        "the requested Patient with no name" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s } },
        "the requested Patient with an empty name list" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s, "name" => [], "gender" => "female" } },
        "the requested Patient named only by text" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s, "name" => [ { "text" => "Bodymarker Textonly" } ] } },
        "the requested Patient with a blank family name" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s, "name" => [ { "family" => "  ", "given" => [] } ] } }
      }.freeze

      # The requested Patient, named, that Patient.from_fhir raises on.
      UNMAPPABLE_ANSWERS = {
        "the requested Patient with a year-only birthDate" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s, "name" => [ { "family" => "Wrongpatient", "given" => [ "Bea" ] } ], "birthDate" => "1980" } },
        "the requested Patient with a year-month birthDate" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s, "name" => [ { "family" => "Wrongpatient", "given" => [ "Bea" ] } ], "birthDate" => "1980-05" } },
        "the requested Patient with a birthDate that is not a date" => ->(dfn) { { "resourceType" => "Patient", "id" => dfn.to_s, "name" => [ { "family" => "Wrongpatient", "given" => [ "Bea" ] } ], "birthDate" => "Bodymarker" } }
      }.freeze

      FAILURE_ANSWERS = WRONG_ANSWERS.merge(NAMELESS_ANSWERS).merge(UNMAPPABLE_ANSWERS).freeze

      # What a FAILURE's error message and log line must never repeat.
      LEAK_MARKERS = %w[99999 424242 Wrongpatient WRONGPATIENT Bea Wrongprovider Bodymarker BODYMARKER Textonly 1980].freeze

      FAILURE_ANSWERS.each do |label, answer|
        test "fhir_first falls back to RPC when FHIR answers #{label}" do
          fhir = AnsweringClient.new(answer.call(1))

          with_fhir_client(fhir) do
            patient = PatientRepository.find(1, source_preference: :fhir_first)

            assert_equal [ [ "Patient", "1" ] ], fhir.reads
            assert_instance_of Patient, patient
            assert_equal :rpc, patient.provenance[:rpms][:source]
            assert_equal 1, patient.dfn
            assert_equal "Anderson,Alice", patient.name
          end
        end

        test "fhir_first raises when RPC does not know the DFN and FHIR answers #{label}" do
          fhir = AnsweringClient.new(answer.call(99999))

          with_fhir_client(fhir) do
            error = assert_raises(CLIENT_ERROR) do
              PatientRepository.find(99999, source_preference: :fhir_first)
            end

            assert_equal [ [ "Patient", "99999" ] ], fhir.reads
            assert_names_nothing error.message
          end
        end

        # Amended: was "rpc_first returns nil when RPC does not know the DFN
        # and FHIR answers ...".
        test "rpc_first raises when RPC does not know the DFN and FHIR answers #{label}" do
          fhir = AnsweringClient.new(answer.call(99999))

          with_fhir_client(fhir) do
            error = assert_raises(CLIENT_ERROR) do
              PatientRepository.find(99999, source_preference: :rpc_first)
            end

            assert_equal [ [ "Patient", "99999" ] ], fhir.reads
            assert_names_nothing error.message
          end
        end
      end

      test "fhir_first falls back to RPC when the test double holds another patient under the requested key" do
        fhir = Lakeraven::EHR::FHIR::MockClient.new
        fhir.seed_resource("Patient", "1", synthetic_patient("2"))

        with_fhir_client(fhir) do
          patient = PatientRepository.find(1, source_preference: :fhir_first)

          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      # Amended: was "rpc_first returns nil when the test double holds another
      # patient under the requested key".
      test "rpc_first raises when the test double holds another patient under the requested key" do
        fhir = Lakeraven::EHR::FHIR::MockClient.new
        fhir.seed_resource("Patient", "99999", synthetic_patient("2"))

        with_fhir_client(fhir) do
          assert_raises(CLIENT_ERROR) do
            PatientRepository.find(99999, source_preference: :rpc_first)
          end
        end
      end

      test "fhir_first raises when the test double holds another patient under the requested key and RPC does not know the DFN" do
        fhir = Lakeraven::EHR::FHIR::MockClient.new
        fhir.seed_resource("Patient", "99999", synthetic_patient("2"))

        with_fhir_client(fhir) do
          assert_raises(CLIENT_ERROR) do
            PatientRepository.find(99999, source_preference: :fhir_first)
          end
        end
      end

      # --- ABSENT: the ordinary miss is nil, never an error ---

      test "fhir_first returns nil when FHIR answers not-found and RPC does not know the DFN" do
        fhir = AnsweringClient.new(not_found_outcome)

        with_fhir_client(fhir) do
          assert_nil PatientRepository.find(99999, source_preference: :fhir_first)
          assert_equal [ [ "Patient", "99999" ] ], fhir.reads
        end
      end

      test "rpc_first returns nil when FHIR answers not-found and RPC does not know the DFN" do
        fhir = AnsweringClient.new(not_found_outcome)

        with_fhir_client(fhir) do
          assert_nil PatientRepository.find(99999, source_preference: :rpc_first)
          assert_equal [ [ "Patient", "99999" ] ], fhir.reads
        end
      end

      test "rpc_first returns nil when the test double has no such patient and RPC does not know the DFN" do
        with_fhir_client(Lakeraven::EHR::FHIR::MockClient.new) do
          assert_nil PatientRepository.find(99999, source_preference: :rpc_first)
        end
      end

      test "fhir_first and rpc_first return nil for an unknown DFN when no FHIR client is configured" do
        with_fhir_client(nil) do
          assert_nil PatientRepository.find(99999, source_preference: :fhir_first)
          assert_nil PatientRepository.find(99999, source_preference: :rpc_first)
        end
      end

      # --- FAILURE by a raised Client::Error, with RPC not knowing the DFN ---

      test "fhir_first raises when the FHIR client fails and RPC does not know the DFN" do
        fhir = AnsweringClient.new(CLIENT_ERROR.new("FHIR Patient request answered 503"))

        with_fhir_client(fhir) do
          error = assert_raises(CLIENT_ERROR) do
            PatientRepository.find(99999, source_preference: :fhir_first)
          end

          assert_equal [ [ "Patient", "99999" ] ], fhir.reads
          assert_names_nothing error.message
        end
      end

      # --- log lines: a FAILURE warns with a truthful reason; a miss does not ---

      test "a not-found miss logs nothing at warn" do
        log = capture_log do
          with_fhir_client(Lakeraven::EHR::FHIR::MockClient.new) do
            assert_equal :rpc, PatientRepository.find(1, source_preference: :fhir_first).provenance[:rpms][:source]
            assert_nil PatientRepository.find(99999, source_preference: :fhir_first)
            assert_nil PatientRepository.find(99999, source_preference: :rpc_first)
          end
        end

        assert_empty warn_lines(log)
      end

      test "an unconfigured FHIR client logs nothing at warn" do
        log = capture_log do
          with_fhir_client(nil) do
            PatientRepository.find(1, source_preference: :fhir_first)
            PatientRepository.find(99999, source_preference: :rpc_first)
          end
        end

        assert_empty warn_lines(log)
      end

      test "a wrong-id answer under fhir_first warns that it was not the requested Patient" do
        fhir = AnsweringClient.new(WRONG_ANSWERS.fetch("a Patient with another id").call(1))
        log = capture_log do
          with_fhir_client(fhir) { PatientRepository.find(1, source_preference: :fhir_first) }
        end

        assert_warned log, "not the requested Patient"
      end

      test "a wrong-id answer under rpc_first warns that it was not the requested Patient" do
        fhir = AnsweringClient.new(WRONG_ANSWERS.fetch("a Patient with another id").call(99999))
        log = capture_log do
          with_fhir_client(fhir) do
            assert_raises(CLIENT_ERROR) { PatientRepository.find(99999, source_preference: :rpc_first) }
          end
        end

        assert_warned log, "not the requested Patient"
      end

      test "a nameless answer warns that it has no usable name" do
        fhir = AnsweringClient.new(NAMELESS_ANSWERS.fetch("the requested Patient named only by text").call(1))
        log = capture_log do
          with_fhir_client(fhir) { PatientRepository.find(1, source_preference: :fhir_first) }
        end

        assert_warned log, "no usable name"
        refute_includes warn_lines(log).join, "not the requested Patient"
      end

      test "an unmappable answer warns that it could not be mapped" do
        fhir = AnsweringClient.new(UNMAPPABLE_ANSWERS.fetch("the requested Patient with a year-only birthDate").call(1))
        log = capture_log do
          with_fhir_client(fhir) { PatientRepository.find(1, source_preference: :fhir_first) }
        end

        assert_warned log, "could not be mapped"
        refute_includes warn_lines(log).join, "not the requested Patient"
      end

      test "a failed FHIR read warns with the client's message under both preferences" do
        fhir = AnsweringClient.new(CLIENT_ERROR.new("FHIR Patient request answered 503"))
        fhir_first = capture_log do
          with_fhir_client(fhir) { PatientRepository.find(1, source_preference: :fhir_first) }
        end
        rpc_first = capture_log do
          with_fhir_client(fhir) do
            assert_raises(CLIENT_ERROR) { PatientRepository.find(99999, source_preference: :rpc_first) }
          end
        end

        assert_warned fhir_first, "FHIR Patient request answered 503"
        assert_warned rpc_first, "FHIR Patient request answered 503"
      end

      test "a found FHIR patient logs nothing at warn" do
        log = capture_log do
          with_fhir_client(seeded_fhir_client("1")) do
            assert_equal :fhir, PatientRepository.find(1, source_preference: :fhir_first).provenance[:rpms][:source]
          end
        end

        assert_empty warn_lines(log)
      end

      # --- an outage is not "no such patient" (#599) ---

      test "rpc_first raises when RPC does not know the DFN and the FHIR client fails" do
        fhir = AnsweringClient.new(Lakeraven::EHR::FHIR::Client::Error.new("FHIR Patient request answered 503"))

        with_fhir_client(fhir) do
          assert_raises(Lakeraven::EHR::FHIR::Client::Error) do
            PatientRepository.find(99999, source_preference: :rpc_first)
          end
          assert_equal [ [ "Patient", "99999" ] ], fhir.reads
        end
      end

      test "rpc_first never asks FHIR when RPC knows the DFN" do
        fhir = AnsweringClient.new(synthetic_patient("1").deep_stringify_keys)

        with_fhir_client(fhir) do
          patient = PatientRepository.find(1, source_preference: :rpc_first)

          assert_empty fhir.reads
          assert_equal :rpc, patient.provenance[:rpms][:source]
          assert_equal "Anderson,Alice", patient.name
        end
      end

      test "rpc_first does not raise for a failing FHIR client when RPC knows the DFN" do
        fhir = AnsweringClient.new(Lakeraven::EHR::FHIR::Client::Error.new("FHIR Patient request answered 503"))

        with_fhir_client(fhir) do
          patient = PatientRepository.find(1, source_preference: :rpc_first)

          assert_empty fhir.reads
          assert_equal :rpc, patient.provenance[:rpms][:source]
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
        client.seed_resource("Patient", id, synthetic_patient(id))
        client
      end

      def synthetic_patient(id)
        {
          resourceType: "Patient", id: id,
          name: [ { family: "Testpatient", given: [ "Ada" ] } ],
          gender: "female", birthDate: "1980-05-15"
        }
      end

      def not_found_outcome
        {
          "resourceType" => "OperationOutcome",
          "issue" => [ { "severity" => "error", "code" => "not-found", "diagnostics" => "Patient not found" } ]
        }
      end

      # Runs the block with Rails.logger swapped for a logger on a StringIO,
      # one "SEVERITY message" line per entry, and returns what was logged.
      def capture_log
        io = StringIO.new
        logger = ActiveSupport::Logger.new(io)
        logger.level = Logger::DEBUG
        logger.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }
        saved = Rails.logger
        Rails.logger = logger
        yield
        io.string
      ensure
        Rails.logger = saved
      end

      def warn_lines(log)
        log.lines.select { |line| line.start_with?("WARN", "ERROR", "FATAL") }
      end

      # One warn line says the reason, and no line at warn or above repeats
      # an id, a name or a piece of the answer.
      def assert_warned(log, reason)
        warned = warn_lines(log)
        assert warned.any? { |line| line.start_with?("WARN") && line.include?(reason) },
               "no WARN line says #{reason.inspect}:\n#{log}"
        assert_names_nothing warned.join
      end

      def assert_names_nothing(text)
        LEAK_MARKERS.each { |marker| refute_includes text, marker }
      end

      # A FHIR client that gives every read the same answer (raising it when
      # it is an exception) and records what it was asked.
      class AnsweringClient
        attr_reader :reads

        def initialize(answer)
          @answer = answer
          @reads = []
        end

        def read(resource_type, id)
          @reads << [ resource_type, id ]
          raise @answer if @answer.is_a?(Exception)

          @answer
        end
      end
    end
  end
end
