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
        @records << report
      end

      def clear!
        @records.clear
      end

      def seed!(records)
        @records = records.dup
      end

      def all
        @records.dup
      end

      def for_patient(dfn)
        @records.select { |report| report.patient_dfn.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |report| report.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
