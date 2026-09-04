# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory DiagnosticReport store (mirrors EncounterStore).
    # DiagnosticReport has no verified live RPC read path — a deployment
    # that can source reports (e.g. a synthetic-sandbox fixture set) seeds
    # DiagnosticReport models here and they are served through the same
    # serializer, search filters, and read-by-id path.
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

      def all
        @records.dup
      end

      def for_patient(dfn)
        @records.select { |r| r.patient_dfn.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |r| r.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
