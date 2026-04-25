# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncounterTest < ActiveSupport::TestCase
      # =============================================================================
      # VALIDATIONS
      # =============================================================================

      test "valid with required attributes" do
        enc = Encounter.new(status: "planned", class_code: "AMB")
        assert enc.valid?
      end

      test "validates status inclusion" do
        enc = Encounter.new(status: "bogus", class_code: "AMB")
        refute enc.valid?
        assert enc.errors[:status].any?
      end

      test "validates class_code inclusion" do
        enc = Encounter.new(status: "planned", class_code: "BOGUS")
        refute enc.valid?
        assert enc.errors[:class_code].any?
      end

      test "accepts all valid statuses" do
        Encounter::VALID_STATUSES.each do |status|
          enc = Encounter.new(status: status, class_code: "AMB")
          assert enc.valid?, "Expected #{status} to be valid"
        end
      end

      test "accepts all valid class codes" do
        Encounter::VALID_CLASS_CODES.each do |code|
          enc = Encounter.new(status: "planned", class_code: code)
          assert enc.valid?, "Expected #{code} to be valid"
        end
      end

      # =============================================================================
      # STATUS PREDICATES
      # =============================================================================

      test "in_progress? true when in-progress" do
        assert Encounter.new(status: "in-progress", class_code: "AMB").in_progress?
      end

      test "in_progress? false when planned" do
        refute Encounter.new(status: "planned", class_code: "AMB").in_progress?
      end

      test "finished? true when finished" do
        assert Encounter.new(status: "finished", class_code: "AMB").finished?
      end

      test "cancelled? true when cancelled" do
        assert Encounter.new(status: "cancelled", class_code: "AMB").cancelled?
      end

      test "planned? true when planned" do
        assert Encounter.new(status: "planned", class_code: "AMB").planned?
      end

      # =============================================================================
      # CLASS PREDICATES
      # =============================================================================

      test "ambulatory? true for AMB" do
        assert Encounter.new(status: "planned", class_code: "AMB").ambulatory?
      end

      test "emergency? true for EMER" do
        assert Encounter.new(status: "planned", class_code: "EMER").emergency?
      end

      test "inpatient? true for IMP" do
        assert Encounter.new(status: "planned", class_code: "IMP").inpatient?
      end

      test "arrived? true for arrived status" do
        assert Encounter.new(status: "arrived", class_code: "AMB").arrived?
      end

      test "virtual? true for VR class" do
        assert Encounter.new(status: "planned", class_code: "VR").virtual?
      end

      # =============================================================================
      # DISPLAY HELPERS
      # =============================================================================

      test "status_display returns human-readable status" do
        assert_equal "In Progress", Encounter.new(status: "in-progress", class_code: "AMB").status_display
        assert_equal "Finished", Encounter.new(status: "finished", class_code: "AMB").status_display
      end

      test "class_display returns human-readable class" do
        assert_equal "Ambulatory", Encounter.new(status: "planned", class_code: "AMB").class_display
        assert_equal "Emergency", Encounter.new(status: "planned", class_code: "EMER").class_display
        assert_equal "Inpatient", Encounter.new(status: "planned", class_code: "IMP").class_display
      end

      # =============================================================================
      # PERIOD HELPERS
      # =============================================================================

      test "within_period? returns true when no period set" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB")
        assert enc.within_period?
      end

      test "within_period? returns true when within period" do
        enc = Encounter.new(
          status: "in-progress", class_code: "AMB",
          period_start: DateTime.current - 1.hour,
          period_end: DateTime.current + 1.hour
        )
        assert enc.within_period?
      end

      test "within_period? returns false when before period" do
        enc = Encounter.new(
          status: "planned", class_code: "AMB",
          period_start: DateTime.current + 1.day
        )
        refute enc.within_period?
      end

      test "within_period? returns false when after period" do
        enc = Encounter.new(
          status: "finished", class_code: "AMB",
          period_end: DateTime.current - 1.day
        )
        refute enc.within_period?
      end

      # =============================================================================
      # WORKFLOW
      # =============================================================================

      test "close sets finished status and period_end" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", period_start: 1.hour.ago)
        result = enc.close
        assert result
        assert enc.finished?
        assert_not_nil enc.period_end
      end

      test "close records reason when provided" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB")
        enc.close(reason_code: "completed", reason_display: "Treatment completed")
        assert_equal "completed", enc.reason_code
        assert_equal "Treatment completed", enc.reason_display
      end

      test "close returns false if already finished" do
        enc = Encounter.new(status: "finished", class_code: "AMB")
        refute enc.close
        assert enc.errors[:status].any?
      end

      test "cancel sets cancelled status" do
        enc = Encounter.new(status: "planned", class_code: "AMB")
        enc.cancel
        assert enc.cancelled?
      end

      # =============================================================================
      # FHIR SERIALIZATION
      # =============================================================================

      test "to_fhir returns Encounter resource" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", ien: 42)
        fhir = enc.to_fhir
        assert_equal "Encounter", fhir[:resourceType]
        assert_equal "42", fhir[:id]
      end

      test "to_fhir includes US Core profile" do
        enc = Encounter.new(status: "planned", class_code: "AMB")
        fhir = enc.to_fhir
        assert_includes fhir.dig(:meta, :profile), Encounter::US_CORE_PROFILE
      end

      test "to_fhir includes class with system" do
        enc = Encounter.new(status: "planned", class_code: "AMB")
        fhir = enc.to_fhir
        assert_equal "AMB", fhir[:class][:code]
        assert_equal "Ambulatory", fhir[:class][:display]
        assert_equal Encounter::ACT_CODE_SYSTEM, fhir[:class][:system]
      end

      test "to_fhir includes period" do
        start = DateTime.new(2024, 1, 15, 10, 0, 0)
        enc = Encounter.new(status: "finished", class_code: "AMB", period_start: start, period_end: start + 1.hour)
        fhir = enc.to_fhir
        assert fhir[:period][:start].present?
        assert fhir[:period][:end].present?
      end

      test "to_fhir omits period when no dates" do
        enc = Encounter.new(status: "planned", class_code: "AMB")
        fhir = enc.to_fhir
        assert_nil fhir[:period]
      end

      test "to_fhir includes subject reference" do
        enc = Encounter.new(status: "planned", class_code: "AMB", patient_identifier: "pt_1")
        fhir = enc.to_fhir
        assert_equal "Patient/pt_1", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes participant" do
        enc = Encounter.new(status: "planned", class_code: "AMB", practitioner_identifier: "pr_101")
        fhir = enc.to_fhir
        assert_equal "Practitioner/pr_101", fhir[:participant].first.dig(:individual, :reference)
      end

      test "to_fhir includes type when present" do
        enc = Encounter.new(status: "planned", class_code: "AMB", type_display: "Office Visit", type_code: "99213")
        fhir = enc.to_fhir
        assert_equal "Office Visit", fhir[:type].first[:text]
      end

      test "to_fhir includes reasonCode when present" do
        enc = Encounter.new(status: "finished", class_code: "AMB", reason_display: "Chest pain", reason_code: "R07.9")
        fhir = enc.to_fhir
        assert_equal "Chest pain", fhir[:reasonCode].first[:text]
      end

      test "to_fhir includes location when present" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", location_ien: 201)
        fhir = enc.to_fhir
        assert fhir[:location].any?
        assert fhir[:location].first.dig(:location, :reference).include?("Location")
      end

      test "to_fhir includes service provider when present" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", service_provider_organization_ien: 301)
        fhir = enc.to_fhir
        assert_not_nil fhir[:serviceProvider]
        assert fhir[:serviceProvider][:reference].include?("Organization")
      end

      test "resource_class returns Encounter" do
        assert_equal "Encounter", Encounter.resource_class
      end

      test "from_fhir_attributes extracts attributes from hash" do
        fhir = {
          status: "finished",
          class: { code: "AMB" },
          subject: { reference: "Patient/12345" }
        }
        attrs = Encounter.from_fhir_attributes(fhir)
        assert_equal "finished", attrs[:status]
        assert_equal "AMB", attrs[:class_code]
        assert_equal "12345", attrs[:patient_identifier]
      end

      # =============================================================================
      # EDGE CASES
      # =============================================================================

      test "to_fhir handles empty participant_practitioner_iens" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", participant_practitioner_iens: [])
        fhir = enc.to_fhir
        assert_nil fhir[:participant]
      end

      test "to_fhir handles nil location" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", location_ien: nil)
        fhir = enc.to_fhir
        assert_nil fhir[:location]
      end

      test "to_fhir handles nil type" do
        enc = Encounter.new(status: "in-progress", class_code: "AMB", type_display: nil)
        fhir = enc.to_fhir
        assert_nil fhir[:type]
      end

      # =============================================================================
      # FHIR DESERIALIZATION
      # =============================================================================

      test "from_fhir creates encounter from hash" do
        fhir = {
          status: "in-progress",
          class: { code: "AMB" },
          period: {
            start: "2024-01-15T10:00:00Z",
            end: "2024-01-15T11:00:00Z"
          }
        }
        enc = Encounter.from_fhir(fhir)
        assert_equal "in-progress", enc.status
        assert_equal "AMB", enc.class_code
        assert_not_nil enc.period_start
        assert_not_nil enc.period_end
      end

      test "from_fhir handles missing period" do
        fhir = { status: "planned", class: { code: "AMB" } }
        enc = Encounter.from_fhir(fhir)
        assert_nil enc.period_start
        assert_nil enc.period_end
      end

      # =============================================================================
      # ROUND-TRIP
      # =============================================================================

      test "to_fhir → from_fhir preserves status and class" do
        enc = Encounter.new(status: "in-progress", class_code: "EMER",
                            period_start: DateTime.new(2024, 1, 15, 10, 0, 0))
        fhir = enc.to_fhir
        parsed = Encounter.from_fhir(fhir)
        assert_equal "in-progress", parsed.status
        assert_equal "EMER", parsed.class_code
      end
    end
  end
end
