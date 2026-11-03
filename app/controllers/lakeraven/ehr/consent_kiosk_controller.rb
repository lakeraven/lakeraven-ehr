# frozen_string_literal: true

module Lakeraven
  module EHR
    # The locked tablet. The patient sees one template, their name, and their
    # date of birth. Staff return by signing on again as the same DUZ.
    class ConsentKioskController < WebController
      include BrowserSmartAuthentication
      include ConsentRequestParameters

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

      def show; end

      def create
        existing = SignedConsent.find_by(handover_token: @consent_lock["handover_token"])
        if existing
          @signed_consent = existing
          render :handed_back
          return
        end

        png = SignedConsent.decode_signature_data_url(consent_request_param(:signature))
        unless png
          @signature_rejected = true
          render :show, status: :unprocessable_entity
          return
        end

        @signed_consent = SignedConsent.record_signature!(signature_attributes(png))
        render :handed_back
      rescue ActiveRecord::RecordInvalid
        @signature_rejected = true
        @signed_consent = nil
        render :show, status: :unprocessable_entity
      end

      def unlock
        result = nil
        begin
          result = AuthenticationService.new.authenticate(
            access_code: consent_request_param(:access_code).to_s,
            verify_code: consent_request_param(:verify_code).to_s,
            client_ip: request.remote_ip
          )
          unless same_clinician?(result)
            note_audit_denial("kiosk unlock refused")
            render plain: "Unlock refused", status: :unprocessable_entity
            return
          end

          dfn = @locked_patient_dfn
          clear_consent_kiosk_lock!
          redirect_to patient_consents_path(dfn)
        ensure
          disconnect_broker_client(result)
        end
      end

      private

      def require_clinician_credential!
        return true if current_duz.present?

        render_forbidden("The consent tablet requires a clinician sign-on")
        false
      end

      def require_consent_lock!
        @consent_lock = consent_kiosk_lock
        @locked_patient_dfn = Patient.canonical_dfn(@consent_lock["dfn"])
        return true if @consent_lock["handover_token"].present? && @locked_patient_dfn.present?

        render plain: "The tablet is not waiting for a consent signature.", status: :forbidden
        false
      end

      def authorize_kiosk_scope!
        allowed = action_name == "create" ? can_write?(CONSENT_RESOURCE) : can_read?(CONSENT_RESOURCE)
        return true if allowed

        render_forbidden("Insufficient scope for the consent tablet")
        false
      end

      def load_kiosk_form!
        @template = locked_template
        unless @template
          render plain: "The consent template for this handover could not be read. Nothing was signed.",
                 status: :not_found
          return
        end

        identity = patient_identity(@locked_patient_dfn)
        if identity
          @patient_name = identity.fetch(:name)
          @patient_dob = identity.fetch(:dob)
          return
        end

        @identity_unavailable = true
        render :show, status: :service_unavailable
      end

      def locked_template
        ConsentTemplate.find_by(
          key: @consent_lock["template_key"],
          version: @consent_lock["template_version"]
        )
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

      def signature_attributes(png)
        {
          patient_dfn: @locked_patient_dfn,
          consent_template: @template,
          template_key: @template.key,
          template_version: @template.version,
          template_body_digest: SignedConsent.digest_for(@template.body),
          signer_name: consent_request_param(:signer_name).to_s.presence,
          signature_png: png,
          signed_at: Time.current,
          witness_duz: current_duz,
          kind: SignedConsent::KIND_SIGNATURE,
          recorded_by_duz: current_duz,
          handover_token: @consent_lock["handover_token"]
        }
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
