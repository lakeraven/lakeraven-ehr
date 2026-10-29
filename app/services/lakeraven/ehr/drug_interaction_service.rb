# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates drug-drug and drug-allergy interaction checking.
    # ONC § 170.315(a)(4) compliance.
    #
    # Pass adapter: to use that object and ignore backend selection.
    # Otherwise AdapterFactory chooses (backend:, else DRUG_INTERACTION_BACKEND,
    # else the local YAML knowledge base). An unavailable backend is incomplete
    # and not safe, with no interactions. A builder that raises is remembered
    # here; check then uses a fixed reason and the requested backend name, never
    # the exception text. An explicit unknown backend or production mock still
    # raises.
    class DrugInteractionService
      UNAVAILABLE_INCOMPLETE_REASON =
        "Drug interaction checking is not available on this server."
      BUILDER_FAILURE_INCOMPLETE_REASON =
        "Drug interaction check could not be completed."

      def initialize(adapter: nil, backend: nil)
        @requested_backend = requested_backend_name(backend)
        if adapter
          @adapter = adapter
          return
        end

        @adapter = DrugInteraction::AdapterFactory.build(backend)
      rescue StandardError, NotImplementedError => e
        raise if e.is_a?(ArgumentError) && DrugInteraction::AdapterFactory.explicit_backend_rejected?(backend)

        @builder_failure = true
      end

      def check(active_medications:, proposed_medication:, allergies:)
        return incomplete_result(BUILDER_FAILURE_INCOMPLETE_REASON) if @builder_failure

        all_meds = active_medications + [ proposed_medication ]

        interactions = []
        interactions.concat(@adapter.check_interactions(all_meds))
        interactions.concat(@adapter.check_allergies(proposed_medication, allergies))

        DrugInteractionResult.new(interactions: interactions, decision_source: decision_source)
      rescue DrugInteraction::AdapterNotAvailable
        incomplete_result(UNAVAILABLE_INCOMPLETE_REASON)
      rescue StandardError, NotImplementedError => e
        incomplete_result(e.message)
      end

      private

      # Same name AdapterFactory would select: explicit backend, else
      # DRUG_INTERACTION_BACKEND, else the local knowledge base.
      def requested_backend_name(backend)
        if backend.nil?
          raw = ENV["DRUG_INTERACTION_BACKEND"].to_s.strip.downcase
          raw.empty? ? :local : raw.to_sym
        elsif backend.is_a?(String) || backend.is_a?(Symbol)
          backend.to_s.strip.downcase.to_sym
        else
          :unknown
        end
      end

      # Adapters that predate #backend keep the historical :local source.
      # StandardError from #backend is :unknown so a rescue path cannot raise.
      def decision_source
        return @requested_backend if @builder_failure
        return :local unless @adapter.respond_to?(:backend)

        @adapter.backend
      rescue NotImplementedError
        :local
      rescue StandardError
        :unknown
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
