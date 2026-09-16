# frozen_string_literal: true

module Lakeraven
  module EHR
    # SmartAuthentication for the HTML clinician surfaces.
    #
    # Same credential, same checks, same failures as the FHIR controllers —
    # only the representation of a refusal differs: a browser gets plain text
    # rather than a FHIR OperationOutcome. ChartsController does the same thing
    # for the HTML chart.
    #
    # Declared as an ActiveSupport::Concern dependency so SmartAuthentication
    # is mixed in FIRST and these overrides take precedence.
    module BrowserSmartAuthentication
      extend ActiveSupport::Concern
      include SmartAuthentication

      # Doorkeeper application that owns every browser sign-on token. It is how
      # a CLINICIAN credential is recognised.
      #
      # `resource_owner_id` is POLYMORPHIC in this codebase —
      # `authorize_patient_context!` compares it to a patient dfn, while a
      # sign-on token carries a clinician DUZ there — so reading it without
      # knowing which kind of token produced it attributes a clinician's act to
      # a patient.
      #
      # THIS BRANCH MUST BE SAFE ALONE. #486 introduces the same constant and
      # the same two predicates in SmartAuthentication; whichever lands first,
      # the name and the value are identical, and every definition below defers
      # to that one once it exists. Nothing here weakens it.
      BROWSER_SSO_APP_NAME =
        if defined?(SmartAuthentication::BROWSER_SSO_APP_NAME)
          SmartAuthentication::BROWSER_SSO_APP_NAME
        else
          "Lakeraven EHR Browser SSO"
        end

      private

      # True when this credential stands for a CLINICIAN — a browser sign-on
      # token, whose `resource_owner_id` is a DUZ.
      #
      # A `patient/` scope is disqualifying on its own, belt to the app-name
      # brace: on a patient-context credential `resource_owner_id` is the
      # PATIENT, and nothing that reads a DUZ may ever be handed one.
      def clinician_credential?
        return false unless current_token

        browser_sso_token?(current_token) && !patient_context_scope?
      end

      def browser_sso_token?(token)
        return super if defined?(super)

        token&.application&.name == BROWSER_SSO_APP_NAME
      end

      # The clinician's DUZ, or nil when there is no clinician behind the
      # request (a patient credential, a backend/system credential, a token
      # from anywhere but the sign-on bridge). Callers FAIL CLOSED on nil
      # rather than falling back to whoever the token happens to name.
      #
      # #486's version adds the half that needs the bridge: the token must also
      # have arrived through the session that minted it, and that session must
      # still name the same DUZ. When it is there it wins outright — this is a
      # floor, never a ceiling.
      def current_duz
        return super if defined?(super)
        return nil unless clinician_credential?

        current_token.resource_owner_id&.to_s.presence
      end

      def render_unauthorized(message = "Unauthorized")
        render plain: "Unauthorized: #{message}", status: :unauthorized
      end

      def render_forbidden(message = "Forbidden")
        render plain: "Forbidden: #{message}", status: :forbidden
      end
    end
  end
end
