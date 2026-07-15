# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientGatewayVistaBackendTest < ActiveSupport::TestCase
      def setup
        @original_backend = Lakeraven::EHR.configuration.backend
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!
      end

      def teardown
        Lakeraven::EHR.configure { |c| c.backend = @original_backend }
        Lakeraven::EHR::Backend.reset!
      end

      test "find returns patient through VistA backend" do
        patient = PatientGateway.find(1)

        assert_not_nil patient
        assert_instance_of Patient, patient
        assert_equal 1, patient.dfn
        assert_equal "Anderson,Alice", patient.name
        assert_equal "F", patient.sex
        assert_equal Date.parse("1980-05-15"), patient.dob
      end

      test "find merges race_code from VistA patient_id_info" do
        patient = PatientGateway.find(1)

        assert_equal "I", patient.race_code
      end

      test "VistA patient serializes to FHIR with US Core extensions" do
        patient = PatientGateway.find(1)
        fhir = patient.to_fhir

        assert_equal "Patient", fhir[:resourceType]
        assert_equal "1", fhir[:id]
        assert_equal "female", fhir[:gender]
        assert_equal "1980-05-15", fhir[:birthDate]

        race_ext = fhir[:extension].find { |e| e[:url]&.include?("us-core-race") }
        refute_nil race_ext

        birthsex_ext = fhir[:extension].find { |e| e[:url]&.include?("us-core-birthsex") }
        refute_nil birthsex_ext
        assert_equal "F", birthsex_ext[:valueCode]
      end

      test "search returns patients through VistA backend" do
        patients = PatientGateway.search("A")

        assert patients.is_a?(Array)
        assert patients.length >= 1
        patients.each { |p| assert_instance_of Patient, p }
      end
    end
  end
end
