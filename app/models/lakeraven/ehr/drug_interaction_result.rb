# frozen_string_literal: true

module Lakeraven
  module EHR
    class DrugInteractionResult
      attr_reader :interactions, :message, :decision_source

      def initialize(interactions: [], message: nil, incomplete: false,
                     decision_source: nil, degraded: false)
        @interactions = interactions
        @message = message
        @incomplete = incomplete
        @decision_source = decision_source
        @degraded = degraded
      end

      def safe?
        interactions.empty? && message.nil? && !@incomplete
      end

      def blocking?
        interactions.any?(&:severe?)
      end

      def incomplete?
        @incomplete
      end

      def degraded?
        @degraded
      end

      def to_fhir_detected_issues
        interactions.map do |alert|
          {
            resourceType: "DetectedIssue",
            severity: alert.severity.to_s,
            code: { text: alert.interaction_type.to_s.tr("_", "-") },
            detail: { text: alert.description },
            implicated: [
              { display: alert.drug_a },
              { display: alert.drug_b }
            ]
          }
        end
      end

      def self.success(decision_source: nil, degraded: false)
        new(interactions: [], decision_source: decision_source, degraded: degraded)
      end

      def self.failure(message:, decision_source: nil, degraded: false)
        new(interactions: [], message: message, decision_source: decision_source, degraded: degraded)
      end
    end
  end
end
