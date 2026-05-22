# frozen_string_literal: true

module Lakeraven
  module EHR
    class EncounterLifecycleService
      Result = Struct.new(:success, :context, :error, keyword_init: true) do
        def success? = success
      end

      # Gateways are constructor-injected so tests can pass fakes without
      # mutating shared global state. Defaults are the production gateways.
      def initialize(dfn, visit_ien, requester: nil,
                     encounter_gateway:  EncounterGateway,
                     patient_gateway:    PatientGateway,
                     observation_gateway: ObservationGateway,
                     condition_gateway:  ConditionGateway,
                     allergy_gateway:    AllergyIntoleranceGateway,
                     reminders_gateway:  RemindersGateway)
        @dfn = dfn
        @visit_ien = visit_ien
        @requester = requester
        @encounter_gateway = encounter_gateway
        @patient_gateway = patient_gateway
        @observation_gateway = observation_gateway
        @condition_gateway = condition_gateway
        @allergy_gateway = allergy_gateway
        @reminders_gateway = reminders_gateway
      end

      # Open an encounter and hydrate the chart context the clinician needs
      # to begin documenting: visit detail, patient brief header, vitals,
      # problem list, allergies, and active reminders. Returns Result.
      #
      # error reasons:
      #   :invalid_input       — dfn or visit_ien missing
      #   :not_found           — visit doesn't exist or doesn't belong to dfn
      #   :permission_denied   — requester lacks :view_patients capability
      #
      # Hydration policy:
      #   - encounter                   — required; nil result yields :not_found
      #   - brief_header                — optional, included as nil if the
      #                                   patient gateway returns nil
      #                                   (chart still renders)
      #   - vitals/problems/allergies   — default to [] if the gateway returns nil
      #   - reminders                   — soft-fail; default to []. The
      #                                   underlying RPC primitive may not have
      #                                   shipped yet (see RemindersGateway).
      #                                   The returned context includes a
      #                                   `reminders_status:` field of
      #                                   :ok | :rpc_unavailable so callers
      #                                   can detect the degraded state
      #                                   rather than treating empty as "no
      #                                   reminders for this patient."
      def open
        return Result.new(success: false, error: :invalid_input) if @dfn.nil? || @visit_ien.nil?
        return Result.new(success: false, error: :permission_denied) unless permitted?

        encounter = @encounter_gateway.open(@dfn, @visit_ien)
        return Result.new(success: false, error: :not_found) if encounter.nil?

        reminders_status = reminders_available? ? :ok : :rpc_unavailable
        context = {
          encounter:         encounter,
          brief_header:      @patient_gateway.brief_header(@dfn),
          vitals:            @observation_gateway.for_patient(@dfn) || [],
          problems:          @condition_gateway.for_patient(@dfn) || [],
          allergies:         @allergy_gateway.for_patient(@dfn) || [],
          reminders:         @reminders_gateway.for_visit(@dfn, @visit_ien) || [],
          reminders_status:  reminders_status
        }

        Result.new(success: true, context: context)
      end

      private

      def permitted?
        return true if @requester.nil? # backwards-compatible: no requester = trust caller
        return false unless @requester.respond_to?(:can?)
        @requester.can?(:view_patients)
      end

      def reminders_available?
        # If the gateway exposes a default_provider check (the production
        # RemindersGateway does), use it. Tests may inject a gateway that
        # doesn't — in that case treat reminders as available since the
        # caller has wired a working fake.
        return true unless @reminders_gateway.respond_to?(:default_provider)
        !@reminders_gateway.default_provider.nil?
      end
    end
  end
end
