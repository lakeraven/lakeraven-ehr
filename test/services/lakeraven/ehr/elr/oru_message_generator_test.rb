# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Elr
      class OruMessageGeneratorTest < ActiveSupport::TestCase
        setup do
          @observation = Observation.new(
            ien: "lab-001", patient_dfn: "12345",
            category: "laboratory",
            code: "11585-7", code_system: "http://loinc.org",
            display: "Hepatitis B virus surface Ag",
            value: "Positive", status: "final",
            effective_datetime: Time.current
          )
          @patient = {
            dfn: "12345",
            name: { given: "Alice", family: "Anderson" },
            dob: "1975-06-15", sex: "F",
            address: { street: "123 Main St", city: "Kingston", state: "NY", zip: "12401" }
          }
          @ordering_provider = { duz: "789", name: "Dr. Smith", npi: "1234567890" }
          @performing_lab = { name: "Ulster County Lab", clia: "33D1234567" }
          @specimen = { type: "BLD", type_display: "Blood", collected_at: Time.current }
        end

        # =====================================================================
        # MESSAGE STRUCTURE
        # =====================================================================

        test "generates HL7 message with MSH segment" do
          msg = generate_oru

          assert msg.include?("MSH|"), "Expected MSH segment"
        end

        test "MSH contains ORU^R01 message type" do
          msg = generate_oru

          msh = segments(msg).find { |l| l.start_with?("MSH|") }
          assert msh.include?("ORU^R01"), "Expected ORU^R01 message type"
        end

        test "MSH contains HL7 version 2.5.1" do
          msg = generate_oru

          msh = segments(msg).find { |l| l.start_with?("MSH|") }
          assert msh.include?("2.5.1"), "Expected HL7 version 2.5.1"
        end

        test "MSH contains ECLRS receiving facility" do
          msg = generate_oru

          msh = segments(msg).find { |l| l.start_with?("MSH|") }
          assert msh.include?("ECLRS"), "Expected ECLRS receiving facility"
        end

        # =====================================================================
        # PATIENT IDENTIFICATION
        # =====================================================================

        test "generates PID segment with patient data" do
          msg = generate_oru

          pid = segments(msg).find { |l| l.start_with?("PID|") }
          assert pid.present?, "Expected PID segment"
          assert pid.include?("Anderson^Alice"), "Expected patient name"
          assert pid.include?("19750615"), "Expected DOB"
        end

        # =====================================================================
        # OBSERVATION REQUEST
        # =====================================================================

        test "generates OBR segment with LOINC code" do
          msg = generate_oru

          obr = segments(msg).find { |l| l.start_with?("OBR|") }
          assert obr.present?, "Expected OBR segment"
          assert obr.include?("11585-7"), "Expected LOINC code in OBR"
        end

        test "OBR includes ordering provider" do
          msg = generate_oru

          obr = segments(msg).find { |l| l.start_with?("OBR|") }
          assert obr.include?("1234567890"), "Expected provider NPI in OBR"
        end

        # =====================================================================
        # OBSERVATION RESULT
        # =====================================================================

        test "generates OBX segment with result" do
          msg = generate_oru

          obx = segments(msg).find { |l| l.start_with?("OBX|") }
          assert obx.present?, "Expected OBX segment"
          assert obx.include?("Positive"), "Expected result value"
        end

        test "OBX includes LOINC code" do
          msg = generate_oru

          obx = segments(msg).find { |l| l.start_with?("OBX|") }
          assert obx.include?("11585-7"), "Expected LOINC code in OBX"
        end

        test "OBX uses ST value type for text results" do
          msg = generate_oru

          obx = segments(msg).find { |l| l.start_with?("OBX|") }
          fields = obx.split("|")
          assert_equal "ST", fields[2], "Expected ST value type for text result"
        end

        test "OBX uses NM value type for numeric results" do
          @observation.value = "42.5"
          @observation.value_quantity = 42.5
          @observation.unit = "mg/dL"
          msg = generate_oru

          obx = segments(msg).find { |l| l.start_with?("OBX|") }
          fields = obx.split("|")
          assert_equal "NM", fields[2], "Expected NM value type for numeric result"
          assert_equal "42.5", fields[5], "Expected numeric value_quantity in OBX-5"
        end

        # =====================================================================
        # ORGANISM CODING
        # =====================================================================

        test "includes organism OBX with SNOMED code" do
          organism = { code: "81665004", display: "Hepatitis B virus", code_system: "http://snomed.info/sct" }
          msg = generate_oru(organism: organism)

          obx_lines = segments(msg).select { |l| l.start_with?("OBX|") }
          assert_equal 2, obx_lines.size, "Expected 2 OBX segments (result + organism)"

          organism_obx = obx_lines[1]
          assert organism_obx.include?("81665004"), "Expected SNOMED code"
          assert organism_obx.include?("Hepatitis B virus"), "Expected organism display"
        end

        # =====================================================================
        # SPECIMEN
        # =====================================================================

        test "generates SPM segment" do
          msg = generate_oru

          spm = segments(msg).find { |l| l.start_with?("SPM|") }
          assert spm.present?, "Expected SPM segment"
          assert spm.include?("BLD^Blood"), "Expected specimen type"
        end

        test "omits SPM when no specimen data" do
          msg = OruMessageGenerator.generate(
            observation: @observation,
            patient: @patient,
            ordering_provider: @ordering_provider,
            performing_lab: @performing_lab
          )

          spm = segments(msg).find { |l| l.start_with?("SPM|") }
          assert_nil spm, "Expected no SPM segment without specimen"
        end

        # =====================================================================
        # HL7 SPECIAL CHARACTER ESCAPING
        # =====================================================================

        test "escapes HL7 special characters in patient name" do
          @patient[:name] = { given: "Mary&Jane", family: "O'Brien|Smith" }
          msg = generate_oru

          pid = segments(msg).find { |l| l.start_with?("PID|") }
          assert pid.include?("O'Brien\\F\\Smith"), "Expected escaped pipe in family name"
          assert pid.include?("Mary\\T\\Jane"), "Expected escaped ampersand in given name"
        end

        test "escapes HL7 special characters in observation value" do
          @observation.value = "Result: positive | confirmed & verified"
          msg = generate_oru

          obx = segments(msg).find { |l| l.start_with?("OBX|1|") }
          assert obx.include?("\\F\\"), "Expected escaped pipe in value"
          assert obx.include?("\\T\\"), "Expected escaped ampersand in value"
        end

        # =====================================================================
        # PERFORMANCE
        # =====================================================================

        test "generation completes within 2 seconds" do
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          generate_oru
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

          assert elapsed < 2.0, "ORU generation took #{elapsed}s"
        end

        private

        def generate_oru(organism: nil)
          OruMessageGenerator.generate(
            observation: @observation,
            patient: @patient,
            ordering_provider: @ordering_provider,
            performing_lab: @performing_lab,
            specimen: @specimen,
            organism: organism
          )
        end

        def segments(msg)
          msg.split("\r").reject(&:blank?)
        end
      end
    end
  end
end
