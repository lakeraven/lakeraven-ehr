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

      private

      # The surfaces this concern serves are server-rendered HTML: their
      # credential arrives in the session the sign-on bridge minted, never in
      # an Authorization header (#486 binds browser tokens to their session
      # and scopes the fallback to HTML surfaces that opt in, like the
      # chart; the FHIR API stays bearer-only).
      def session_token_fallback_allowed?
        true
      end

      # True when this credential stands for a CLINICIAN — a browser sign-on
      # token, whose `resource_owner_id` is a DUZ.
      #
      # `browser_sso_token?` is #486's predicate (SmartAuthentication), keyed
      # on the intrinsic `browser_session` flag stamped on the token at mint
      # — never on a renameable application label. This branch used to carry
      # a name-keyed fallback for the pre-#486 world; the bridge is merged
      # now, so the one predicate is the only predicate.
      #
      # A `patient/` scope is disqualifying on its own, belt to that brace:
      # `resource_owner_id` is POLYMORPHIC in this codebase — a patient dfn
      # on a patient-context credential, a clinician DUZ on a sign-on token —
      # and nothing that reads a DUZ may ever be handed a patient's.
      # (`current_duz`, also #486's, applies the same two checks itself.)
      def clinician_credential?
        return false unless current_token

        browser_sso_token?(current_token) && !patient_context_scope?
      end

      def render_unauthorized(message = "Unauthorized")
        note_audit_denial(message) if respond_to?(:note_audit_denial, true)
        render plain: "Unauthorized: #{message}", status: :unauthorized
      end

      def render_forbidden(message = "Forbidden")
        note_audit_denial(message) if respond_to?(:note_audit_denial, true)
        render plain: "Forbidden: #{message}", status: :forbidden
      end
    end
  end
end
