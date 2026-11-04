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
    # This gate asks whether the session is over, and the shared gate may
    # ask again. When this ask says it is over, that decision stands: record
    # it and end the session here, so a later ask that disagrees cannot
    # still serve the page. When this ask says the session is alive and the
    # shared gate ends it anyway, record that ending against the DUZ from
    # before the reset. The kiosk-lock redirect sits immediately before this
    # gate, still inside the audit wrapper, so a locked consent list does
    # not refresh the idle clock.
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
          session_gate = callback_named(chain, :require_authentication)
          audit_at = chain.to_a.index { |callback| callback.filter == :audit_clinical_access }
          unless session_gate && audit_at
            raise "session authentication could not be placed inside the audit wrapper"
          end

          chain.delete(session_gate)
          chain.insert(audit_at + 1, session_gate)
          place_kiosk_lock_before_session_gate!(chain)
        end

        def place_kiosk_lock_before_session_gate!(chain)
          lock_gate = callback_named(chain, :redirect_when_consent_kiosk_locked)
          return unless lock_gate

          chain.delete(lock_gate)
          auth_at = chain.to_a.index { |callback| callback.filter == :require_authentication }
          chain.insert(auth_at, lock_gate)
        end

        def callback_named(chain, filter)
          chain.to_a.find { |callback| callback.filter == filter }
        end
      end

      private

      def require_authentication
        duz_at_gate = session[:duz].to_s.presence
        reason = ending_session_reason
        if reason
          act_on_session_end!(duz_at_gate, reason)
        else
          super
          note_super_session_end!(duz_at_gate)
        end
      end

      def act_on_session_end!(duz, reason)
        @duz_before_session_end = duz
        note_audit_denial(reason)
        redirect_for_session_end!(reason)
      end

      # The shared gate ended a session this check had allowed. Record that
      # ending against the DUZ captured before the reset.
      def note_super_session_end!(duz)
        return if duz.blank? || session[:duz].present? || @audit_denial_reason.present?

        @duz_before_session_end = duz
        note_audit_denial(reason_for_super_session_end)
      end

      def reason_for_super_session_end
        alert = flash[:alert].to_s
        return "browser access refused: RPMS session ended" if alert.match?(/RPMS session ended/i)
        return "browser access refused: session ended" if alert.match?(/session ended/i)

        "browser access refused: session timed out"
      end

      def redirect_for_session_end!(reason)
        return end_session_for_closed_rpms! if reason.include?("RPMS session ended")

        terminate_session!
        redirect_to login_path, alert: session_end_alert(reason)
      end

      def session_end_alert(reason)
        if reason.include?("timed out")
          "Your session timed out. Please sign in again."
        else
          "Your session ended. Please sign in again."
        end
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
