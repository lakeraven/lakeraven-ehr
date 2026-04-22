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
    end
  end
end
