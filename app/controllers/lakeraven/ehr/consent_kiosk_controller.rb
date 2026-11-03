# frozen_string_literal: true

module Lakeraven
  module EHR
    # The locked tablet. The patient sees one template, their name, and their
    # date of birth. Staff return by signing on again as the same DUZ.
    class ConsentKioskController < WebController
      include BrowserSmartAuthentication

      CONSENT_RESOURCE = "Consent"
      layout "lakeraven/ehr/kiosk"

      # The lock's job is to send every other page here. This page is the
      # destination, so it must not redirect to itself.
      skip_before_action :redirect_when_consent_kiosk_locked

      before_action :authenticate_smart_token!
      before_action :require_clinician_credential!
      before_action :require_consent_lock!
      before_action :authorize_kiosk_scope!
      before_action :load_kiosk_form!, only: %i[show create]

      def show
        render :handed_back if stored_handover_signature
      end

      def create
        return refuse_repeated_signature! if signature_refusals_exhausted?
        return reject_signature! if @template.nil?
        return render_stored_signature! if stored_handover_signature

        parsed = SignedConsent.decode_signature_data_url(params[:signature])
        return reject_signature! unless parsed

        store_posted_signature!(parsed)
      rescue ActiveRecord::RecordInvalid
        reject_signature!
      end

      def unlock
        result = nil
        return if throttled_unlock?

        result = authenticate_for_unlock
        return if refused_unlock?(result)

        finish_unlock!
      ensure
        disconnect_broker_client(result)
      end

      private

      def require_clinician_credential!
        return true if current_duz.present?

        render_forbidden("The consent tablet requires a clinician sign-on")
        false
      end

      def require_consent_lock!
        if kiosk_lock_unreadable?
          render plain: "The consent lock could not be read, so the tablet stays closed.",
                 status: :service_unavailable
          return false
        end

        @consent_lock = consent_kiosk_lock
        @locked_patient_dfn = Patient.canonical_dfn(@consent_lock["dfn"])
        return true if lock_ready?

        render plain: "The tablet is not waiting for a consent signature.", status: :forbidden
        false
      end

      def lock_ready?
        @consent_lock["handover_token"].present? && @locked_patient_dfn.present?
      end

      def authorize_kiosk_scope!
        allowed = action_name == "create" ? can_write?(CONSENT_RESOURCE) : can_read?(CONSENT_RESOURCE)
        return true if allowed

        render_forbidden("Insufficient scope for the consent tablet")
        false
      end

      def load_kiosk_form!
        @template = locked_template
        return true if @template.nil?

        assign_patient_identity!
      end

      def assign_patient_identity!
        identity = patient_identity(@locked_patient_dfn)
        if identity
          @patient_name = identity.fetch(:name)
          @patient_dob = identity.fetch(:dob)
          return true
        end

        @identity_unavailable = true
        render :show, status: :service_unavailable
        false
      end

      def locked_template
        ConsentTemplate.find_by(key: @consent_lock["template_key"], version: @consent_lock["template_version"])
      end

      # Name and date of birth come from the patient record. A miss is a
      # refusal, not a blank line. The rescue stays on this lookup: an RPC
      # failure arrives as StandardError, and its message can carry the record.
      def patient_identity(dfn)
        patient = Patient.find_by_dfn(dfn)
        return nil if patient.nil?

        name = patient.display_name.to_s.strip
        dob = PatientBanner::Demographics.format_dob(patient.dob)
        return nil if name.blank? || dob.blank? || dob == PatientBanner::MISSING

        { name: name, dob: dob }
      rescue StandardError => error
        Rails.logger.warn("[consent-kiosk] patient identity could not be read: #{error.class}")
        nil
      end

      def stored_handover_signature
        @signed_consent = SignedConsent.find_by(handover_token: @consent_lock["handover_token"])
      end

      def reject_signature!
        return render_refusal_uncounted unless count_signature_refusal

        @signature_rejected = true
        @signed_consent = nil
        render :show, status: :unprocessable_entity
      end

      # Checked before the PNG is decoded. Ten refusals on this handover
      # close the post; a cookie cannot reset a count that lives on the lock.
      def signature_refusals_exhausted?
        lock = active_kiosk_lock
        return false if lock.nil?

        lock.refused_signatures_exhausted?
      rescue StandardError => error
        Rails.logger.error("[consent-kiosk] signature refusal count could not be read: #{error.class}")
        @signature_refusal_count_unreadable = true
        true
      end

      def count_signature_refusal
        lock = active_kiosk_lock
        return true if lock.nil?

        lock.increment!(:refused_signature_count)
        true
      rescue StandardError => error
        Rails.logger.error("[consent-kiosk] signature refusal was not counted: #{error.class}")
        false
      end

      def refuse_repeated_signature!
        note_audit_denial(repeated_signature_reason)
        render plain: repeated_signature_reason, status: repeated_signature_status
      end

      def repeated_signature_reason
        if @signature_refusal_count_unreadable
          "The count of refused signatures could not be read, so this signature was refused."
        else
          "Too many refused signatures for this handover."
        end
      end

      def repeated_signature_status
        @signature_refusal_count_unreadable ? :service_unavailable : :too_many_requests
      end

      def render_refusal_uncounted
        note_audit_denial("consent signature refused: the refusal count could not be stored")
        render plain: "The refused signature could not be counted, so another signature was refused.",
               status: :service_unavailable
      end

      # A racing second post gets the row already stored for this handover.
      # Audit that as a read, the same as a resubmit of a stored signature.
      def store_posted_signature!(parsed)
        @signed_consent = SignedConsent.record_signature!(signature_attributes(parsed))
        @consent_audit_action = "R" if @signed_consent.already_stored?
        render :handed_back
      end

      def signature_attributes(parsed)
        {
          patient_dfn: @locked_patient_dfn, consent_template: @template,
          template_key: @template.key, template_version: @template.version,
          template_body_digest: SignedConsent.digest_for(@template.body),
          signer_name: params[:signer_name].to_s.presence, signature_png: parsed.bytes,
          decoded_signature: parsed, signed_at: Time.current, witness_duz: current_duz,
          kind: SignedConsent::KIND_SIGNATURE, recorded_by_duz: current_duz,
          handover_token: @consent_lock["handover_token"]
        }
      end

      # A second post of a signature already stored for this handover reads
      # the hand-back page. It must not be audited as another consent create.
      def render_stored_signature!
        @consent_audit_action = "R"
        render :handed_back
      end

      def throttled_unlock?
        return false unless LoginThrottle.throttled?(submitted_access_code, request.remote_ip)

        render plain: "Too many sign-in attempts. Try again later.", status: :too_many_requests
        true
      end

      def submitted_access_code
        params[:access_code].to_s
      end

      def authenticate_for_unlock
        AuthenticationService.new.authenticate(
          access_code: submitted_access_code,
          verify_code: params[:verify_code].to_s,
          client_ip: request.remote_ip
        )
      rescue RpmsRpc::Client::ConnectionError, RpmsRpc::NotConfiguredError, Errno::ECONNREFUSED,
             IOError, SocketError, RpmsRpc::Client::RpcError, RpmsRpc::Client::AuthenticationError => error
        Rails.logger.error("[consent-kiosk] unlock unavailable: #{error.class}")
        nil
      end

      # Who signed on is checked before verify-must-change. Another person's
      # must-change code is a failed unlock. The same person's must-change
      # is still refused, and is not counted as a bad code.
      def refused_unlock?(result)
        return render_unlock_unavailable if result.nil?
        unless same_clinician?(result)
          record_unlock_failure
          return true
        end
        return render_verify_must_change if verify_must_change?(result)

        false
      end

      def render_unlock_unavailable
        render plain: "RPMS is unavailable right now. Try again shortly.", status: :service_unavailable
        true
      end

      def render_verify_must_change
        note_audit_denial("kiosk unlock refused: verify code must be changed")
        render plain: "Your verify code must be changed before the tablet can be unlocked.", status: :forbidden
        true
      end

      def record_unlock_failure
        LoginThrottle.record_failure(submitted_access_code, request.remote_ip)
        note_audit_denial("kiosk unlock refused")
        render plain: "Unlock refused.", status: :unprocessable_entity
      end

      def finish_unlock!
        LoginThrottle.clear_account(submitted_access_code)
        dfn = @locked_patient_dfn
        unless clear_consent_kiosk_lock!
          render plain: "The tablet lock could not be cleared, so it stays locked.", status: :service_unavailable
          return
        end

        redirect_to patient_consents_path(dfn)
      end

      def verify_must_change?(result)
        return false unless result&.success?

        value = result.value
        return false unless value.respond_to?(:[])

        value[:verify_needs_change] || value["verify_needs_change"]
      end

      def same_clinician?(result)
        return false unless result&.success?

        returned = result.value[:duz].to_s.presence || result.value["duz"].to_s.presence
        expected = session[:duz].to_s.presence
        returned.present? && expected.present? && returned == expected && returned == current_duz.to_s
      end

      def disconnect_broker_client(result)
        client = broker_client(result)
        return unless client.respond_to?(:disconnect)

        client.disconnect
      rescue StandardError => error
        Rails.logger.warn("[consent-kiosk] broker client disconnect failed: #{error.class}")
      end

      def broker_client(result)
        value = result&.value
        return nil unless value.respond_to?(:[])

        value[:client] || value["client"]
      end

      # Session end has to be a refusal with a reason. The shared gate clears
      # the session before the audit row is written, which would otherwise
      # look like nothing worth recording.
      def require_authentication
        note_ending_kiosk_session!
        super
      end

      def note_ending_kiosk_session!
        reason = ending_kiosk_session_reason
        note_audit_denial(reason) if reason
      end

      def ending_kiosk_session_reason
        return nil if session[:duz].blank?
        return "browser access refused: session timed out" if session_idle_expired? || session_lifetime_expired?
        return "browser access refused: session ended" if session_token_revoked?
        return "browser access refused: RPMS session ended" if rpms_connection_closed?

        nil
      end

      # Unlock releases the tablet. It is an execute, not a consent create.
      # A resubmit of a stored signature is a read.
      def audit_action
        return @consent_audit_action if @consent_audit_action
        return "E" if action_name == "unlock"

        super
      end

      def audit_outcome_desc
        described = super
        return described unless action_name == "unlock"
        return described if described.to_s.match?(/unlock|kiosk|lock/i)

        [ described, "kiosk unlock" ].compact.join("; ").presence
      end

      def fhir_resource_type
        consent_audit_id ? CONSENT_RESOURCE : "Patient"
      end

      def direct_audit_identifier
        consent_audit_id || @locked_patient_dfn
      end

      def consent_audit_id
        @signed_consent.id.to_s if @signed_consent&.persisted?
      end

      # require_authentication has to sit after the audit around-callback
      # (so a session ending is recorded) and before CSRF (so a stale token
      # cannot turn that ending into a 401). Prepend puts it outside the
      # wrapper; a normal before_action puts it after CSRF.
      def self.place_session_authentication_inside_audit!
        before_action :require_authentication
        chain = _process_action_callbacks
        ordered = chain.to_a
        session_gate = ordered.find { |callback| callback.filter == :require_authentication }
        audit_at = ordered.index { |callback| callback.filter == :audit_clinical_access }
        unless session_gate && audit_at
          raise "consent kiosk authentication could not be placed inside the audit wrapper"
        end

        chain.delete(session_gate)
        chain.insert(audit_at + 1, session_gate)
      end
      private_class_method :place_session_authentication_inside_audit!
      # Inside the audit wrapper, and before CSRF. Prepending would record
      # nothing when the session ends; appending would let a stale token
      # turn that ending into a 401 instead of a redirect to login.
      place_session_authentication_inside_audit!
    end
  end
end
