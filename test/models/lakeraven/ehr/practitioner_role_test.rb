# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class PractitionerRoleTest < ActiveSupport::TestCase
      # =========================================================================
      # HELPERS
      # =========================================================================

      def valid_attributes
        { practitioner_ien: 101, organization_ien: 100 }
      end

      # =========================================================================
      # ATTRIBUTE TESTS
      # =========================================================================

      test "has practitioner and organization references" do
        pr = PractitionerRole.new(practitioner_ien: 101, organization_ien: 1, role: "doctor", specialty: "Cardiology")
        assert_equal 101, pr.practitioner_ien
        assert_equal "Doctor", pr.role_display
      end

      test "defaults to active" do
        assert PractitionerRole.new.active?
      end

      # =========================================================================
      # VALIDATION TESTS
      # =========================================================================

      test "valid with required attributes" do
        pr = PractitionerRole.new(valid_attributes)
        assert pr.valid?, "PractitionerRole should be valid: #{pr.errors.full_messages}"
      end

      test "requires practitioner_ien" do
        pr = PractitionerRole.new(valid_attributes.merge(practitioner_ien: nil))
        refute pr.valid?
        assert pr.errors[:practitioner_ien].any?
      end

      test "requires organization_ien" do
        pr = PractitionerRole.new(valid_attributes.merge(organization_ien: nil))
        refute pr.valid?
        assert pr.errors[:organization_ien].any?
      end

      test "validates practitioner_ien is positive" do
        pr = PractitionerRole.new(valid_attributes.merge(practitioner_ien: 0))
        refute pr.valid?
        assert pr.errors[:practitioner_ien].any?
      end

      test "validates organization_ien is positive" do
        pr = PractitionerRole.new(valid_attributes.merge(organization_ien: 0))
        refute pr.valid?
        assert pr.errors[:organization_ien].any?
      end

      test "validates role if present" do
        pr = PractitionerRole.new(valid_attributes.merge(role: "invalid"))
        refute pr.valid?
        assert_includes pr.errors[:role], "is not included in the list"
      end

      test "allows blank role" do
        pr = PractitionerRole.new(valid_attributes)
        assert pr.valid?
      end

      # =========================================================================
      # STATUS HELPER TESTS
      # =========================================================================

      test "active? returns true for active roles" do
        pr = PractitionerRole.new(valid_attributes.merge(active: true))
        assert pr.active?
      end

      test "active? returns false for inactive roles" do
        pr = PractitionerRole.new(valid_attributes.merge(active: false))
        refute pr.active?
      end

      test "valid_for_scheduling? checks active and period" do
        pr = PractitionerRole.new(valid_attributes.merge(active: true))
        assert pr.valid_for_scheduling?

        pr.active = false
        refute pr.valid_for_scheduling?
      end

      # =========================================================================
      # PERIOD TESTS
      # =========================================================================

      test "within_period? true when no dates" do
        assert PractitionerRole.new.within_period?
      end

      test "within_period? true when current" do
        pr = PractitionerRole.new(period_start: 1.year.ago, period_end: 1.year.from_now)
        assert pr.within_period?
      end

      test "within_period? false when expired" do
        pr = PractitionerRole.new(period_start: 2.years.ago, period_end: 1.year.ago)
        refute pr.within_period?
      end

      test "within_period? true when end_date in future" do
        pr = PractitionerRole.new(period_start: 1.month.ago, period_end: 1.month.from_now)
        assert pr.within_period?
      end

      test "within_period? false when end_date in past" do
        pr = PractitionerRole.new(period_start: 2.years.ago, period_end: 1.year.ago)
        refute pr.within_period?
      end

      test "within_period? true when only start_date" do
        pr = PractitionerRole.new(period_start: 1.year.ago)
        assert pr.within_period?
      end

      test "within_period? false when before period start" do
        pr = PractitionerRole.new(valid_attributes.merge(period_start: Date.current + 1.month))
        refute pr.within_period?
      end

      # =========================================================================
      # ROLE DISPLAY TESTS
      # =========================================================================

      test "role_display capitalizes role" do
        pr = PractitionerRole.new(role: "nurse")
        assert_equal "Nurse", pr.role_display
      end

      test "role_display returns Unknown for nil" do
        pr = PractitionerRole.new(role: nil)
        assert_equal "Unknown", pr.role_display
      end

      test "role_display returns mapped display values" do
        pr = PractitionerRole.new(role: "doctor")
        assert_equal "Doctor", pr.role_display

        pr.role = "pharmacist"
        assert_equal "Pharmacist", pr.role_display
      end

      # =========================================================================
      # FHIR SERIALIZATION TESTS
      # =========================================================================

      test "to_fhir returns PractitionerRole resource" do
        pr = PractitionerRole.new(practitioner_ien: 101, organization_ien: 1, role: "doctor", active: true)
        fhir = pr.to_fhir
        assert_equal "PractitionerRole", fhir[:resourceType]
        assert_equal "Practitioner/101", fhir.dig(:practitioner, :reference)
      end

      test "to_fhir includes organization reference" do
        pr = PractitionerRole.new(practitioner_ien: 101, organization_ien: 1)
        fhir = pr.to_fhir
        assert_equal "Organization/1", fhir.dig(:organization, :reference)
      end

      test "to_fhir includes active status" do
        pr = PractitionerRole.new(practitioner_ien: 101, active: true)
        fhir = pr.to_fhir
        assert_equal true, fhir[:active]
      end

      test "to_fhir includes specialty" do
        pr = PractitionerRole.new(practitioner_ien: 101, specialty: "Cardiology")
        fhir = pr.to_fhir
        assert fhir[:specialty]&.any?
        assert_equal "Cardiology", fhir[:specialty].first[:text]
      end

      test "to_fhir includes code for role" do
        pr = PractitionerRole.new(practitioner_ien: 101, role: "doctor")
        fhir = pr.to_fhir
        assert fhir[:code]&.any?
        code = fhir[:code].first
        assert_equal "doctor", code.dig(:coding, 0, :code)
        assert_equal "Doctor", code.dig(:coding, 0, :display)
      end

      test "to_fhir includes location references" do
        pr = PractitionerRole.new(valid_attributes.merge(location_iens: [ 200, 201 ]))
        fhir = pr.to_fhir
        assert_equal 2, fhir[:location].count
        refs = fhir[:location].map { |l| l[:reference] }
        assert refs.any? { |r| r.include?("200") }
        assert refs.any? { |r| r.include?("201") }
      end

      test "to_fhir includes period" do
        pr = PractitionerRole.new(valid_attributes.merge(
          period_start: Date.parse("2024-01-01"),
          period_end: Date.parse("2024-12-31")
        ))
        fhir = pr.to_fhir
        assert_not_nil fhir[:period]
        assert_equal "2024-01-01", fhir[:period][:start]
        assert_equal "2024-12-31", fhir[:period][:end]
      end

      test "to_fhir handles empty location_iens" do
        pr = PractitionerRole.new(valid_attributes.merge(location_iens: []))
        fhir = pr.to_fhir
        assert_equal [], fhir[:location]
      end

      test "to_fhir handles nil period dates" do
        pr = PractitionerRole.new(valid_attributes.merge(period_start: nil, period_end: nil))
        fhir = pr.to_fhir
        assert_nil fhir[:period]
      end

      test "resource_class returns PractitionerRole" do
        assert_equal "PractitionerRole", PractitionerRole.resource_class
      end

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          active: true,
          practitioner: OpenStruct.new(reference: "Practitioner/101"),
          organization: OpenStruct.new(reference: "Organization/100"),
          specialty: [ OpenStruct.new(text: "Family Medicine") ],
          period: OpenStruct.new(start: "2024-01-01", end: "2024-12-31")
        )

        attrs = PractitionerRole.from_fhir_attributes(fhir_resource)
        assert_equal 101, attrs[:practitioner_ien]
        assert_equal 100, attrs[:organization_ien]
        assert_equal "Family Medicine", attrs[:specialty]
        assert_equal true, attrs[:active]
        assert_equal Date.parse("2024-01-01"), attrs[:period_start]
        assert_equal Date.parse("2024-12-31"), attrs[:period_end]
      end

      test "from_fhir creates practitioner role from FHIR resource" do
        fhir_resource = OpenStruct.new(
          active: true,
          practitioner: OpenStruct.new(reference: "Practitioner/101"),
          organization: OpenStruct.new(reference: "Organization/100"),
          specialty: [],
          period: nil
        )

        pr = PractitionerRole.from_fhir(fhir_resource)
        assert pr.is_a?(PractitionerRole)
        assert_equal 101, pr.practitioner_ien
        assert_equal 100, pr.organization_ien
      end

      # =========================================================================
      # US CORE / TEFCA COMPLIANCE TESTS
      # =========================================================================

      test "FHIR is US Core compliant with practitioner and organization" do
        pr = PractitionerRole.new(valid_attributes.merge(
          specialty: "Family Medicine", role: "doctor", active: true
        ))
        fhir = pr.to_fhir
        assert fhir[:practitioner].present?, "US Core requires practitioner reference"
        assert fhir[:organization].present?, "Should have organization reference"
      end

      test "supports external specialist lookup via FHIR" do
        pr = PractitionerRole.new(valid_attributes.merge(specialty: "Cardiology"))
        fhir = pr.to_fhir
        assert fhir[:practitioner].present?
        assert fhir[:organization].present?
        assert fhir[:specialty]&.any?, "Specialty helps with specialist matching"
      end

      test "can be serialized to JSON" do
        pr = PractitionerRole.new(valid_attributes.merge(specialty: "Cardiology"))
        assert_nothing_raised { pr.as_json }
      end
    end
  end
end
