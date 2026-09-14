# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clinical audit that FAILS CLOSED.
    #
    # `AuditableClinicalAccess` records after the fact, best effort: a failed
    # insert was logged and the response — the PHI — went out anyway, and a
    # request refused by a `before_action` produced no audit at all, because an
    # `after_action` on a halted filter chain never runs. Refused accesses are
    # exactly the ones worth recording.
    #
    # So the audit happens AROUND the action instead:
    #
    #   * a refusal (403) and a raised exception are recorded, not just a 200;
    #   * if the access cannot be recorded, it is not completed — the response
    #     is replaced with 503 and the controller is given a chance to undo any
    #     state the action established (`rollback_unrecorded_access`).
    #
    # If it can't be written down, it didn't happen.
    module FailClosedClinicalAudit
      extend ActiveSupport::Concern
      include AuditableClinicalAccess

      included do
        # This concern owns the audit for these controllers; the best-effort
        # after_action the shared concern installs would double-record.
        skip_after_action :record_audit_event, raise: false
        around_action :audit_clinical_access
      end

      private

      # The action's work and its audit row commit TOGETHER or not at all.
      #
      # Auditing after the action, outside a transaction, is fail-open on any
      # action that writes: a self-harm-flagged administration landed durably
      # with zero audit rows while the clinician was told it had not been
      # completed. A read that goes unaudited costs a log line; an unaudited
      # WRITE leaves a clinical record the audit log has never heard of.
      #
      # `requires_new: true` is deliberate: a plain nested `transaction` joins
      # its parent, and `ActiveRecord::Rollback` inside a joined transaction is
      # silently discarded — the rollback would not happen under an enclosing
      # transaction (and every test runs inside one).
      def audit_clinical_access
        @audit_failure = nil
        recorded = false

        ActiveRecord::Base.transaction(requires_new: true) do
          begin
            yield
          rescue StandardError => e
            # Roll back whatever the action wrote before it failed; the attempt
            # is recorded below, outside the transaction, so the failure itself
            # does not become invisible.
            @audit_failure = e
            raise ActiveRecord::Rollback
          end

          recorded = recorded_clinical_access?
          raise ActiveRecord::Rollback unless recorded
        end

        if @audit_failure
          recorded_clinical_access?
          raise @audit_failure
        end

        return if recorded

        rollback_unrecorded_access
        deny_unrecorded_access
      end

      def recorded_clinical_access?
        record_audit_event!
        true
      rescue StandardError => e
        Rails.logger.error("[audit] refusing to serve an unrecorded clinical access: #{e.message}")
        false
      end

      # An action that established state (an opened patient record) undoes it
      # here: state the audit log has no record of must not survive the request.
      def rollback_unrecorded_access; end

      # Throws away EVERYTHING the action produced — a rendered page, a
      # redirect, and the flash that redirect set — and answers 503 instead.
      #
      # `response_body = nil` resets the response but leaves
      # ActionController::Metal's own `@_response_body` set, which `render`
      # reads to decide it is being called twice; a discarded redirect would
      # otherwise leave its Location header behind; and the flash is written to
      # the SESSION COOKIE rather than the response body, so without clearing
      # it "PHQ-9 recorded — score 24, severe" survived the refusal and
      # rendered on the clinician's next page — a score for a record that was
      # never written.
      def deny_unrecorded_access
        self.response_body = nil
        @_response_body = nil
        response.delete_header("Location")
        flash.clear
        flash.discard
        render plain: "Service Unavailable: this access could not be recorded, so it was not completed",
               status: :service_unavailable
      end

      # An exception never reached a status code, so it is a serious failure
      # rather than whatever the half-built response happens to say.
      def audit_outcome
        @audit_failure ? "8" : super
      end
    end
  end
end
