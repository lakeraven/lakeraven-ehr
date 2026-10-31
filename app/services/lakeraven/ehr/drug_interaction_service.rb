# frozen_string_literal: true

module Lakeraven
  module EHR
    # Orchestrates drug-drug and drug-allergy interaction checking.
    # ONC § 170.315(a)(4) compliance.
    #
    # Pass adapter: to use that object and ignore backend selection.
    # Otherwise AdapterFactory chooses (backend:, else DRUG_INTERACTION_BACKEND,
    # else the local YAML knowledge base). The requested name is computed only
    # then; if that read raises, the name is :unknown and the check is
    # incomplete. An unavailable backend is incomplete and not safe, with no
    # interactions. A builder that raises StandardError or ScriptError is
    # remembered here; check then uses a fixed reason and the requested
    # backend name, never the exception text. Each check must return an Array
    # of InteractionAlert; anything else is incomplete and not safe, with no
    # interactions. An explicit unknown backend or production mock still
    # raises.
    class DrugInteractionService
      UNAVAILABLE_INCOMPLETE_REASON =
        "Drug interaction checking is not available on this server."
      BUILDER_FAILURE_INCOMPLETE_REASON =
        "Drug interaction check could not be completed."
      UNEXPECTED_RESULT_INCOMPLETE_REASON =
        "Drug interaction check returned an unexpected result."

      def initialize(adapter: nil, backend: nil)
        if adapter
          @adapter = adapter
          return
        end

        @requested_backend = requested_backend_name(backend)
        @adapter = DrugInteraction::AdapterFactory.build(backend)
      rescue StandardError, ScriptError => e
        raise if e.is_a?(ArgumentError) && DrugInteraction::AdapterFactory.explicit_backend_rejected?(backend)

        # A raise while reading the name leaves it unset.
        @requested_backend ||= :unknown
        @builder_failure = true
      end

      def check(active_medications:, proposed_medication:, allergies:)
        return incomplete_result(BUILDER_FAILURE_INCOMPLETE_REASON) if @builder_failure

        interactions = interaction_alerts_for(active_medications, proposed_medication, allergies)
        return incomplete_result(UNEXPECTED_RESULT_INCOMPLETE_REASON) unless interactions

        DrugInteractionResult.new(interactions: interactions, decision_source: decision_source)
      rescue DrugInteraction::AdapterNotAvailable
        incomplete_result(UNAVAILABLE_INCOMPLETE_REASON)
      rescue StandardError, ScriptError => e
        incomplete_result(e.message)
      end

      private

      # Same name AdapterFactory would select: explicit backend, else
      # DRUG_INTERACTION_BACKEND, else the local knowledge base. Called only
      # when no adapter was injected. If this raises, initialize keeps :unknown.
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

      # LocalAdapter returns Array<InteractionAlert>. nil, a non-array, or any
      # other element means the check did not complete.
      def interaction_alerts_for(active_medications, proposed_medication, allergies)
        all_meds = active_medications + [ proposed_medication ]
        drug_alerts = @adapter.check_interactions(all_meds)
        return unless interaction_alert_list?(drug_alerts)

        allergy_alerts = @adapter.check_allergies(proposed_medication, allergies)
        return unless interaction_alert_list?(allergy_alerts)

        drug_alerts + allergy_alerts
      end

      def interaction_alert_list?(alerts)
        alerts.is_a?(Array) && alerts.all?(InteractionAlert)
      end

      # Adapters that predate #backend keep the historical :local source.
      # NotImplementedError from #backend stays :local. StandardError and any
      # other ScriptError are :unknown so a rescue path cannot raise.
      def decision_source
        return @requested_backend if @builder_failure
        return :local unless @adapter.respond_to?(:backend)

        @adapter.backend
      rescue NotImplementedError
        :local
      rescue StandardError, ScriptError
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
