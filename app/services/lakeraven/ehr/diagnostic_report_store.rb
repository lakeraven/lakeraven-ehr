# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory diagnostic report store for FHIR DiagnosticReport reads.
    # Replaces DiagnosticReport lookups with a plain Ruby collection.
    class DiagnosticReportStore
      def initialize
        @records = []
      end

      def self.instance
        @instance ||= new
      end

      def self.reset_instance!
        @instance = new
      end

      def add(report)
        validate(report)
        @records << report
      end

      def clear!
        @records.clear
      end

      def seed!(records)
        raise ArgumentError, "records must be an Array" unless records.is_a?(Array)

        records.each { |report| validate(report) }
        @records = records.dup
      end

      def all
        @records.dup
      end

      def for_patient(dfn)
        return [] if dfn.blank?

        @records.select { |report| report.patient_dfn.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |report| report.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end

      private

      def validate(report)
        raise ArgumentError, "record is nil" if report.nil?
        raise ArgumentError, "patient_dfn is blank" if report.patient_dfn.blank?
      end
    end
  end
end
