# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class CareTeamTest < ActiveSupport::TestCase
      # =============================================================================
      # MODEL ATTRIBUTES
      # =============================================================================

      test "has required attributes" do
        team = CareTeam.new(
          ien: "123",
          patient_dfn: "456",
          name: "Diabetes Care Team",
          status: "active"
        )

        assert_equal "123", team.ien
        assert_equal "456", team.patient_dfn
        assert_equal "Diabetes Care Team", team.name
        assert_equal "active", team.status
      end

      test "validates patient_dfn presence" do
        team = CareTeam.new(name: "Care Team")
        assert_not team.valid?
        assert_includes team.errors[:patient_dfn], "can't be blank"
      end

      test "validates status values" do
        team = CareTeam.new(patient_dfn: "123", status: "invalid")
        assert_not team.valid?
        assert_includes team.errors[:status], "is not included in the list"
      end

      test "allows valid status values" do
        %w[proposed active suspended inactive entered-in-error].each do |status|
          team = CareTeam.new(patient_dfn: "123", status: status)
          assert team.valid?, "Expected #{status} to be valid"
        end
      end

      test "allows blank status" do
        team = CareTeam.new(patient_dfn: "123")
        assert team.valid?
      end

      test "accepts participants array" do
        participants = [
          { "duz" => "123", "name" => "Dr. Smith", "role" => "Primary Care" },
          { "duz" => "456", "name" => "Nurse Jones", "role" => "Care Manager" }
        ]

        team = CareTeam.new(patient_dfn: "123", participants: participants)

        assert_equal 2, team.participants.length
        assert_equal "Dr. Smith", team.participants.first["name"]
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      test "to_fhir returns valid FHIR structure" do
        team = CareTeam.new(
          ien: "123",
          patient_dfn: "456",
          name: "Diabetes Care Team",
          status: "active"
        )

        fhir = team.to_fhir

        assert_equal "CareTeam", fhir[:resourceType]
        assert_equal "rpms-ct-123", fhir[:id]
        assert_includes fhir[:meta][:profile], "http://hl7.org/fhir/us/core/StructureDefinition/us-core-careteam"
      end

      test "to_fhir includes status and name" do
        team = CareTeam.new(
          ien: "123", patient_dfn: "456",
          name: "Primary Care Team", status: "active"
        )

        fhir = team.to_fhir

        assert_equal "active", fhir[:status]
        assert_equal "Primary Care Team", fhir[:name]
      end

      test "to_fhir includes patient reference" do
        team = CareTeam.new(ien: "123", patient_dfn: "456")

        fhir = team.to_fhir

        assert_equal "Patient/rpms-456", fhir[:subject][:reference]
      end

      test "to_fhir includes participants" do
        participants = [
          { "duz" => "789", "name" => "Dr. Smith", "role" => "Primary Care Provider" }
        ]

        team = CareTeam.new(ien: "123", patient_dfn: "456", participants: participants)

        fhir = team.to_fhir

        assert_equal 1, fhir[:participant].length
        assert_equal "Practitioner/rpms-789", fhir[:participant].first[:member][:reference]
        assert_equal "Dr. Smith", fhir[:participant].first[:member][:display]
      end

      test "to_fhir includes category" do
        team = CareTeam.new(ien: "123", patient_dfn: "456")

        fhir = team.to_fhir

        assert_equal 1, fhir[:category].length
        coding = fhir[:category].first[:coding].first
        assert_equal "LA27976-2", coding[:code]
        assert_equal "http://loinc.org", coding[:system]
      end

      test "to_fhir includes period" do
        team = CareTeam.new(
          ien: "123", patient_dfn: "456",
          period_start: Date.new(2026, 1, 1),
          period_end: Date.new(2026, 12, 31)
        )

        fhir = team.to_fhir

        assert_equal "2026-01-01", fhir[:period][:start]
        assert_equal "2026-12-31", fhir[:period][:end]
      end

      test "to_fhir omits period when no dates" do
        team = CareTeam.new(ien: "123", patient_dfn: "456")
        fhir = team.to_fhir
        assert_nil fhir[:period]
      end

      test "to_fhir includes reason code" do
        team = CareTeam.new(
          ien: "123", patient_dfn: "456",
          reason_code: "E11.9", reason_display: "Diabetes mellitus"
        )
        fhir = team.to_fhir

        assert_not_nil fhir[:reasonCode]
        assert_equal "Diabetes mellitus", fhir[:reasonCode].first[:text]
      end

      test "to_fhir includes managing organization" do
        team = CareTeam.new(
          ien: "123", patient_dfn: "456",
          managing_organization: "Alaska Native Medical Center"
        )
        fhir = team.to_fhir

        assert_not_nil fhir[:managingOrganization]
        assert_equal "Alaska Native Medical Center", fhir[:managingOrganization].first[:display]
      end

      # =============================================================================
      # RESOURCE CLASS & PERSISTENCE
      # =============================================================================

      test "resource_class returns CareTeam" do
        assert_equal "CareTeam", CareTeam.resource_class
      end

      test "persisted? returns true when ien present" do
        team = CareTeam.new(ien: "123", patient_dfn: "456")
        assert team.persisted?
      end

      test "persisted? returns false when ien blank" do
        team = CareTeam.new(patient_dfn: "456")
        assert_not team.persisted?
      end

      test "id returns ien" do
        team = CareTeam.new(ien: "123", patient_dfn: "456")
        assert_equal "123", team.id
      end

      test "from_fhir_attributes extracts name and status" do
        fhir = OpenStruct.new(name: "Test Team", status: "active")
        attrs = CareTeam.from_fhir_attributes(fhir)
        assert_equal "Test Team", attrs[:name]
        assert_equal "active", attrs[:status]
      end
    end
  end
end
