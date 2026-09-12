# frozen_string_literal: true

module Lakeraven
  module EHR
    # AuditableClinicalAccess for the SESSION-authenticated web surface.
    #
    # The shared concern is written for the FHIR controllers, where the agent
    # is a Doorkeeper application. Here the agent is the signed-in clinician
    # (DUZ from the session established at sign-on) and there is no token, so
    # these hooks replace the token branch. They live here rather than in the
    # shared concern, which the FHIR controllers depend on.
    #
    # Declared as an ActiveSupport::Concern dependency so the shared concern is
    # mixed in FIRST and these overrides take precedence.
    module SessionAuditedClinicalAccess
      extend ActiveSupport::Concern
      include AuditableClinicalAccess

      private

      def current_token = nil

      # Fixed marker, per the shared concern's contract: it answers only "is
      # this request auditable at all?". The acting identity is below.
      def unauthenticated_audit_actor = ("clinician-session" if session[:duz].present?)

      def audit_agent_attributes
        { agent_who_type: "Practitioner", agent_who_identifier: session[:duz] }
      end
    end
  end
end
