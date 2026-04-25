# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientSogiTest < ActiveSupport::TestCase
      # =============================================================================
      # SOGI Attributes (ONC 170.315(a)(15)) — ported from rpms_redux
      # =============================================================================

      test "patient accepts sexual_orientation attribute" do
        patient = Patient.new(
          dfn: 1, name: "TEST,PATIENT", sex: "F",
          sexual_orientation: "Straight or heterosexual"
        )
        assert_equal "Straight or heterosexual", patient.sexual_orientation
      end

      test "patient accepts gender_identity attribute" do
        patient = Patient.new(
          dfn: 1, name: "TEST,PATIENT", sex: "F",
          gender_identity: "Identifies as female"
        )
        assert_equal "Identifies as female", patient.gender_identity
      end

      # =============================================================================
      # FHIR Extensions
      # =============================================================================

      test "to_fhir includes sexual orientation FHIR extension" do
        patient = Patient.new(
          dfn: 1, name: "TEST,PATIENT", sex: "F",
          sexual_orientation: "Straight or heterosexual"
        )
        fhir = patient.to_fhir

        so_ext = fhir[:extension].find { |e| e[:url] == "http://hl7.org/fhir/StructureDefinition/patient-sexualOrientation" }
        assert_not_nil so_ext, "Should have sexual orientation extension"
        assert_equal "Straight or heterosexual", so_ext[:valueString]
      end

      test "to_fhir includes gender identity FHIR extension" do
        patient = Patient.new(
          dfn: 1, name: "TEST,PATIENT", sex: "F",
          gender_identity: "Identifies as female"
        )
        fhir = patient.to_fhir

        gi_ext = fhir[:extension].find { |e| e[:url] == "http://hl7.org/fhir/StructureDefinition/patient-genderIdentity" }
        assert_not_nil gi_ext, "Should have gender identity extension"
        assert_equal "Identifies as female", gi_ext[:valueString]
      end

      test "to_fhir omits SOGI extensions when values are blank" do
        patient = Patient.new(dfn: 1, name: "TEST,PATIENT", sex: "F")
        fhir = patient.to_fhir

        extensions = fhir[:extension] || []
        so_ext = extensions.find { |e| e[:url]&.include?("sexualOrientation") }
        gi_ext = extensions.find { |e| e[:url]&.include?("genderIdentity") }

        assert_nil so_ext, "Should not have sexual orientation extension when blank"
        assert_nil gi_ext, "Should not have gender identity extension when blank"
      end

      test "to_fhir preserves existing extensions alongside SOGI" do
        patient = Patient.new(
          dfn: 1, name: "TEST,PATIENT", sex: "F",
          race: "AMERICAN INDIAN OR ALASKA NATIVE",
          sexual_orientation: "Bisexual",
          gender_identity: "Non-binary"
        )
        fhir = patient.to_fhir

        extensions = fhir[:extension] || []
        race_ext = extensions.find { |e| e[:url]&.include?("us-core-race") }
        so_ext = extensions.find { |e| e[:url]&.include?("sexualOrientation") }
        gi_ext = extensions.find { |e| e[:url]&.include?("genderIdentity") }

        assert_not_nil race_ext, "Should preserve race extension"
        assert_not_nil so_ext, "Should have sexual orientation extension"
        assert_not_nil gi_ext, "Should have gender identity extension"
      end
    end
  end
end
