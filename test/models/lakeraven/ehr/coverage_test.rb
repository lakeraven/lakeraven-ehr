# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CoverageTest < ActiveSupport::TestCase
      test "creates with required attributes" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", subscriber_id: "MCD123")
        assert cov.valid?
        assert_equal "active", cov.status
      end

      test "validates patient_dfn presence" do
        cov = Coverage.new(coverage_type: "medicaid")
        assert_not cov.valid?
        assert_includes cov.errors[:patient_dfn], "can't be blank"
      end

      test "validates coverage_type inclusion" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "bogus")
        assert_not cov.valid?
      end

      test "validates status inclusion" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", status: "bogus")
        assert_not cov.valid?
      end

      # -- Status helpers ------------------------------------------------------

      test "active? checks status and period" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid",
                           start_date: 1.year.ago, end_date: 1.year.from_now)
        assert cov.active?
      end

      test "active? returns false when expired" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid",
                           start_date: 2.years.ago, end_date: 1.year.ago)
        assert_not cov.active?
      end

      test "expired? checks end_date" do
        cov = Coverage.new(patient_dfn: "1", coverage_type: "medicaid", end_date: 1.day.ago)
        assert cov.expired?
      end

      # -- Payor helpers -------------------------------------------------------

      test "medicare? checks coverage_type prefix" do
        assert Coverage.new(coverage_type: "medicare_a").medicare?
        assert Coverage.new(coverage_type: "medicare_b").medicare?
        assert_not Coverage.new(coverage_type: "medicaid").medicare?
      end

      test "government_payer? includes medicare, medicaid, va" do
        assert Coverage.new(coverage_type: "medicare_a").government_payer?
        assert Coverage.new(coverage_type: "medicaid").government_payer?
        assert Coverage.new(coverage_type: "va_benefits").government_payer?
        assert_not Coverage.new(coverage_type: "private_insurance").government_payer?
      end

      # -- COB -----------------------------------------------------------------

      test "primary? and secondary?" do
        assert Coverage.new(order: 1).primary?
        assert Coverage.new(order: 2).secondary?
      end

      # -- FHIR serialization --------------------------------------------------

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
        assert_equal "2025-01-01", fhir.dig(:period, :start)
      end
    end
  end
end
