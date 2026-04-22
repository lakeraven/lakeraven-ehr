# frozen_string_literal: true

module Lakeraven
  module EHR
    class InteractionAlert
      attr_reader :severity, :drug_a, :drug_b, :description, :source, :interaction_type

      def initialize(severity:, drug_a:, drug_b:, description:, source: nil, interaction_type: :drug_drug)
        @severity = severity
        @drug_a = drug_a
        @drug_b = drug_b
        @description = description
        @source = source
        @interaction_type = interaction_type
      end

      def severe?
        severity == :high
      end
    end
  end
end
