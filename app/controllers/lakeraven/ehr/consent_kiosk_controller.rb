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
      # Before CSRF. An idle or revoked handover has to reach login; a stale
      # authenticity token must not turn that into a 401 loop.
      prepend_before_action :require_authentication

      before_action :authenticate_smart_token!
      before_action :require_clinician_credential!
      before_action :require_consent_lock!
      before_action :authorize_kiosk_scope!
      before_action :load_kiosk_form!, only: %i[show create]

      def show; end

      def create
        return reject_signature! if @template.nil?
        return render :handed_back if stored_handover_signature

        png = SignedConsent.decode_signature_data_url(params[:signature])
        return reject_signature! unless png

        @signed_consent = SignedConsent.record_signature!(signature_attributes(png))
        render :handed_back
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
        @signature_rejected = true
        @signed_consent = nil
        render :show, status: :unprocessable_entity
      end

      def signature_attributes(png)
        {
          patient_dfn: @locked_patient_dfn, consent_template: @template,
          template_key: @template.key, template_version: @template.version,
          template_body_digest: SignedConsent.digest_for(@template.body),
          signer_name: params[:signer_name].to_s.presence, signature_png: png,
          signed_at: Time.current, witness_duz: current_duz,
          kind: SignedConsent::KIND_SIGNATURE, recorded_by_duz: current_duz,
          handover_token: @consent_lock["handover_token"]
        }
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

      def refused_unlock?(result)
        return render_unlock_unavailable if result.nil?
        return render_verify_must_change if verify_must_change?(result)
        return false if same_clinician?(result)

        record_unlock_failure
        true
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

      def fhir_resource_type
        consent_audit_id ? CONSENT_RESOURCE : "Patient"
      end

      def direct_audit_identifier
        consent_audit_id || @locked_patient_dfn
      end

      def consent_audit_id
        @signed_consent.id.to_s if @signed_consent&.persisted?
      end
    end
  end
end
