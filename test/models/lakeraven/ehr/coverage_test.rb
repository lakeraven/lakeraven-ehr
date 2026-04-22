# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoverageTest < ActiveSupport::TestCase
      # -- Creation + defaults ---------------------------------------------------

      test "creates with required attributes" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid")
        assert cov.valid?
      end

      test "defaults status to active" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid")
        assert_equal "active", cov.status
      end

      test "defaults relationship to self" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid")
        assert_equal "self", cov.relationship
      end

      # -- Validation ------------------------------------------------------------

      test "requires patient_dfn" do
        cov = Coverage.new(coverage_type: "medicaid")
        assert_not cov.valid?
        assert_includes cov.errors[:patient_dfn], "can't be blank"
      end

      test "requires coverage_type" do
        cov = Coverage.new(patient_dfn: "1")
        assert_not cov.valid?
      end

      test "validates coverage_type inclusion" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "bogus")
        assert_not cov.valid?
      end

      test "validates status inclusion" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "bogus")
        assert_not cov.valid?
      end

      test "accepts all valid coverage types" do
        Coverage::COVERAGE_TYPES.each do |type|
          cov = Coverage.new(patient_dfn: "1", coverage_type: type)
          assert cov.valid?, "Expected #{type} to be valid"
        end
      end

      test "accepts all valid statuses" do
        Coverage::VALID_STATUSES.each do |status|
          cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: status)
          assert cov.valid?, "Expected status #{status} to be valid"
        end
      end

      # -- Status helpers --------------------------------------------------------

      test "active? true when active and within period" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid",
                           start_date: 1.year.ago, end_date: 1.year.from_now)
        assert cov.active?
      end

      test "active? false when cancelled" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "cancelled")
        assert_not cov.active?
      end

      test "active? false when expired" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid",
                           start_date: 2.years.ago, end_date: 1.year.ago)
        assert_not cov.active?
      end

      test "expired? true when end_date past" do
        assert Coverage.new(end_date: 1.day.ago).expired?
      end

      test "expired? false when no end_date" do
        assert_not Coverage.new.expired?
      end

      test "within_coverage_period? true when no dates set" do
        assert Coverage.new.within_coverage_period?
      end

      test "cancelled? checks status" do
        assert Coverage.new(status: "cancelled").cancelled?
      end

      # -- Payor helpers ---------------------------------------------------------

      test "medicare? checks prefix" do
        assert Coverage.new(coverage_type: "medicare_a").medicare?
        assert Coverage.new(coverage_type: "medicare_b").medicare?
        assert Coverage.new(coverage_type: "medicare_d").medicare?
        assert_not Coverage.new(coverage_type: "medicaid").medicare?
      end

      test "medicaid?" do
        assert Coverage.new(coverage_type: "medicaid").medicaid?
      end

      test "private_insurance?" do
        assert Coverage.new(coverage_type: "private_insurance").private_insurance?
      end

      test "va_benefits?" do
        assert Coverage.new(coverage_type: "va_benefits").va_benefits?
      end

      test "government_payer? includes medicare, medicaid, va" do
        assert Coverage.new(coverage_type: "medicare_a").government_payer?
        assert Coverage.new(coverage_type: "medicaid").government_payer?
        assert Coverage.new(coverage_type: "va_benefits").government_payer?
        assert_not Coverage.new(coverage_type: "private_insurance").government_payer?
        assert_not Coverage.new(coverage_type: "workers_comp").government_payer?
      end

      # -- COB -------------------------------------------------------------------

      test "primary? and secondary?" do
        assert Coverage.new(order: 1).primary?
        assert Coverage.new(order: 2).secondary?
        assert_not Coverage.new(order: 1).secondary?
      end

      # -- FHIR serialization ----------------------------------------------------

      test "to_fhir returns Coverage resource" do
        cov = Coverage.new(
          patient_dfn: "1", coverage_type: "medicaid", status: "active",
          payor_name: "State Medicaid", subscriber_id: "MCD123",
          start_date: Date.new(2025, 1, 1), end_date: Date.new(2025, 12, 31)
        )
        fhir = cov.to_fhir

        assert_equal "Coverage", fhir[:resourceType]
        assert_equal "active", fhir[:status]
        assert_equal "Patient/1", fhir.dig(:beneficiary, :reference)
      end

      test "to_fhir includes period when dates set" do
        cov = Coverage.new(
          patient_dfn: "1", coverage_type: "medicaid",
          start_date: Date.new(2025, 1, 1), end_date: Date.new(2025, 12, 31)
        )
        fhir = cov.to_fhir

        assert_equal "2025-01-01", fhir.dig(:period, :start)
        assert_equal "2025-12-31", fhir.dig(:period, :end)
      end

      test "to_fhir includes payor" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", payor_name: "State Medicaid")
        fhir = cov.to_fhir

        assert_equal "State Medicaid", fhir[:payor].first[:display]
      end

      test "to_fhir includes class with subscriber_id" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", subscriber_id: "MCD123")
        fhir = cov.to_fhir

        plan_class = fhir[:class]&.find { |c| c.dig(:type, :coding, 0, :code) == "plan" }
        assert_equal "MCD123", plan_class[:value]
      end
    end
  end
end
