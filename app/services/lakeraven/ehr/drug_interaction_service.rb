# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates drug-drug and drug-allergy interaction checking.
    # ONC § 170.315(a)(4) compliance.
    #
    # Pass adapter: to use that object and ignore backend selection.
    # Otherwise AdapterFactory chooses (backend:, else DRUG_INTERACTION_BACKEND,
    # else the local YAML knowledge base). An unavailable backend is incomplete
    # and not safe, with no interactions.
    class DrugInteractionService
      UNAVAILABLE_INCOMPLETE_REASON =
        "Drug interaction checking is not available on this server."

      def initialize(adapter: nil, backend: nil)
        @adapter = adapter || DrugInteraction::AdapterFactory.build(backend)
      end

      def check(active_medications:, proposed_medication:, allergies:)
        all_meds = active_medications + [ proposed_medication ]

        interactions = []
        interactions.concat(@adapter.check_interactions(all_meds))
        interactions.concat(@adapter.check_allergies(proposed_medication, allergies))

        DrugInteractionResult.new(interactions: interactions, decision_source: decision_source)
      rescue DrugInteraction::AdapterNotAvailable
        incomplete_result(UNAVAILABLE_INCOMPLETE_REASON)
      rescue => e
        incomplete_result(e.message)
      end

      private

      # Adapters that predate #backend keep the historical :local source.
      def decision_source
        return :local unless @adapter.respond_to?(:backend)

        @adapter.backend
      rescue NotImplementedError
        :local
      end

      def incomplete_result(reason)
        DrugInteractionResult.new(
          interactions: [],
          incomplete: true,
          incomplete_reason: reason,
          decision_source: decision_source
        )
      end
    end
  end
end
