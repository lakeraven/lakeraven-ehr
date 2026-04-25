# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VaersReportTest < ActiveSupport::TestCase
      # -- Validations -----------------------------------------------------------

      test "valid with all required fields" do
        report = build_vaers_report
        assert report.valid?, "Expected report to be valid: #{report.errors.full_messages}"
      end

      test "requires patient_dfn" do
        report = build_vaers_report(patient_dfn: nil)
        refute report.valid?
        assert report.errors[:patient_dfn].any?
      end

      test "requires immunization_id" do
        report = build_vaers_report(immunization_id: nil)
        refute report.valid?
        assert report.errors[:immunization_id].any?
      end

      # -- CSV export ------------------------------------------------------------

      test "to_csv generates valid CSV string" do
        report = build_vaers_report
        csv = report.to_csv
        assert csv.is_a?(String)
        assert csv.include?("VAERS_ID")
        assert csv.include?("VACCINE_TYPE")
      end

      test "to_csv includes adverse event text" do
        report = build_vaers_report(adverse_event: "Fever and chills")
        csv = report.to_csv
        assert csv.include?("Fever and chills")
      end

      # -- ActiveModel behavior --------------------------------------------------

      test "is not persisted" do
        refute build_vaers_report.persisted?
      end

      test "responds to ActiveModel API" do
        report = VaersReport.new
        assert report.respond_to?(:valid?)
        assert report.respond_to?(:errors)
        assert report.respond_to?(:to_csv)
      end

      test "to_vaers returns hash representation" do
        report = build_vaers_report
        vaers = report.to_vaers
        assert_equal "COVID-19", vaers[:vaccine_name]
        assert_equal "M", vaers[:patient_sex]
      end

      private

      def build_vaers_report(overrides = {})
        defaults = {
          patient_dfn: "1",
          immunization_id: "42",
          patient_name: "PATIENT,TEST",
          patient_dob: Date.new(1985, 5, 5),
          patient_sex: "M",
          vaccine_name: "COVID-19",
          vaccine_date: Date.new(2025, 1, 15),
          adverse_event: "Fever and chills",
          onset_date: Date.new(2025, 1, 16)
        }
        VaersReport.new(defaults.merge(overrides))
      end
    end
  end
end
