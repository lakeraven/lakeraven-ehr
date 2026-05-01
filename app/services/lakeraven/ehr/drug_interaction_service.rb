# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates drug-drug and drug-allergy interaction checking.
    # ONC § 170.315(a)(4) compliance.
    #
    # Accepts a pluggable adapter (default: YAML mock adapter).
    # Production adapters: RPMS Pharmacy RPC, NLM DailyMed, FDB.
    class DrugInteractionService
      def initialize(adapter: nil)
        @adapter = adapter || DrugInteraction::MockAdapter.new
      end

      def check(active_medications:, proposed_medication:, allergies:)
        all_meds = active_medications + [proposed_medication]

        interactions = []
        interactions.concat(@adapter.check_interactions(all_meds))
        interactions.concat(@adapter.check_allergies(proposed_medication, allergies))

        DrugInteractionResult.new(interactions: interactions, decision_source: :local)
      rescue => e
        DrugInteractionResult.new(
          interactions: [], incomplete: true,
          incomplete_reason: e.message, decision_source: :local
        )
      end
    end
  end
end
