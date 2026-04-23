# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PractitionerRoleTest < ActiveSupport::TestCase
      test "has practitioner and organization references" do
        pr = PractitionerRole.new(practitioner_ien: 101, organization_ien: 1, role: "doctor", specialty: "Cardiology")
        assert_equal 101, pr.practitioner_ien
        assert_equal "Doctor", pr.role_display
      end

      test "defaults to active" do
        assert PractitionerRole.new.active?
      end

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
      end

      test "to_fhir includes code for role" do
        pr = PractitionerRole.new(practitioner_ien: 101, role: "doctor")
        fhir = pr.to_fhir
        assert fhir[:code]&.any?
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

      test "role_display capitalizes role" do
        pr = PractitionerRole.new(role: "nurse")
        assert_equal "Nurse", pr.role_display
      end

      test "role_display handles nil" do
        pr = PractitionerRole.new(role: nil)
        assert_nil pr.role_display
      end
    end
  end
end
