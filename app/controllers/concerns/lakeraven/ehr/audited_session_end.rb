# frozen_string_literal: true

module Lakeraven
  module EHR
    # Session end on a consent surface is a refusal with a staff DUZ.
    #
    # The shared gate clears `session[:duz]` before the audit row is written.
    # Noting the reason and the DUZ first is what makes the row exist and name
    # the person. The gate has to sit after the audit around-callback (so that
    # ending is inside the wrapper) and before CSRF (so resetting the session
    # cannot turn the ending into a 422, and before the SMART check, which
    # would answer 401 once the token is gone).
    #
    # Prepend puts the gate outside the wrapper. A normal `before_action`
    # puts it after CSRF. Both consent controllers include this so the two
    # cannot drift. Other browser pages keep their own gate.
    module AuditedSessionEnd
      extend ActiveSupport::Concern

      included do
        place_session_authentication_inside_audit!
      end

      class_methods do
        private

        def place_session_authentication_inside_audit!
          before_action :require_authentication
          chain = _process_action_callbacks
          ordered = chain.to_a
          session_gate = ordered.find { |callback| callback.filter == :require_authentication }
          audit_at = ordered.index { |callback| callback.filter == :audit_clinical_access }
          unless session_gate && audit_at
            raise "session authentication could not be placed inside the audit wrapper"
          end

          chain.delete(session_gate)
          chain.insert(audit_at + 1, session_gate)
        end
      end

      private

      def require_authentication
        note_ending_session!
        super
      end

      def note_ending_session!
        reason = ending_session_reason
        return unless reason

        @duz_before_session_end = session[:duz].to_s.presence
        note_audit_denial(reason)
      end

      # Idle covers the site limit and a shorter RPMS DTIME. Lifetime is the
      # absolute sign-on cap. Both are "session timed out".
      def ending_session_reason
        return nil if session[:duz].blank?
        return "browser access refused: session timed out" if idle_or_lifetime_expired?
        return "browser access refused: session ended" if session_token_revoked?
        return "browser access refused: RPMS session ended" if rpms_connection_closed?

        nil
      end

      def idle_or_lifetime_expired?
        session_idle_expired? || session_lifetime_expired?
      end

      # The row is written after the gate clears the session. Keep the DUZ
      # that was present when the ending was decided.
      def resolved_clinician_duz
        noted = @duz_before_session_end
        return noted if noted.present? && session[:duz].blank?

        super
      end
    end
  end
end
