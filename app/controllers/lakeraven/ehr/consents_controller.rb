# frozen_string_literal: true

module Lakeraven
  module EHR
    # Staff side of in-clinic consent (#793). The list is the chart's consent
    # view. Handover locks the session onto the kiosk. Revocation adds a row;
    # the signature is not updated. There is no edit route.
    class ConsentsController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext

      CONSENT_RESOURCE = "Consent"
      TEMPLATES_MISSING = "No consent templates are installed, so handover is unavailable. " \
                          "Install them with bin/rails lakeraven_ehr:consent_templates:install."

      before_action :authenticate_smart_token!
      before_action :authorize_consent_scope!
      before_action :require_clinician_credential!, only: %i[handover revocation]
      before_action :load_patient
      before_action :enforce_token_patient_context!
      before_action :enforce_patient_context!

      def index
        @consents = SignedConsent.signatures_for_patient(@dfn).includes(:consent_template)
        @revocations_by_signature_id = revocations_for(@consents)
      end

      def new
        @templates = ConsentTemplate::KEYS.filter_map { |key| ConsentTemplate.current(key) }
        @templates_missing_reason = TEMPLATES_MISSING if @templates.empty?
      end

      def handover
        template = ConsentTemplate.current(params[:template_key])
        return render_missing_template if template.nil?
        return render_lock_refused unless lock_tablet!(template)

        redirect_to consent_kiosk_path
      end

      def revocation
        signature = SignedConsent.signatures_for_patient(@dfn).find_by(id: params[:id])
        unless signature
          render plain: "Consent not found", status: :not_found
          return
        end

        @signed_consent = signature.revoke!(by_duz: current_duz, reason: params[:reason])
        redirect_to patient_consents_path(@dfn)
      rescue SignedConsent::NotRevocable, ActiveRecord::RecordInvalid
        render plain: "This consent was not revoked.", status: :unprocessable_entity
      end

      private

      def authorize_consent_scope!
        return true if consent_scope_permitted?

        verb = request.get? ? "read" : "record"
        render_forbidden("Insufficient scope to #{verb} consent")
        false
      end

      def consent_scope_permitted?
        if request.get?
          can_read?(CONSENT_RESOURCE)
        else
          can_write?(CONSENT_RESOURCE)
        end
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      def require_clinician_credential!
        return true if current_duz.present?

        render_forbidden("Recording a consent requires a clinician sign-on")
        false
      end

      def load_patient
        @dfn = Patient.canonical_dfn(params[:dfn]) || params[:dfn]
      end

      def lock_tablet!(template)
        store_consent_kiosk_lock!(
          dfn: @dfn, template_key: template.key, template_version: template.version,
          handover_token: SecureRandom.uuid
        )
      end

      def render_missing_template
        reason = ConsentTemplate.none? ? TEMPLATES_MISSING : "Unknown consent template"
        render plain: reason, status: :not_found
      end

      def render_lock_refused
        note_audit_denial("consent handover refused: the tablet could not be locked")
        render plain: "The tablet could not be locked to this sign-on, so the handover was refused.",
               status: :unprocessable_entity
      end

      def revocations_for(consents)
        ids = consents.map(&:id)
        return {} if ids.empty?

        SignedConsent.where(kind: SignedConsent::KIND_REVOCATION, revokes_id: ids).index_by(&:revokes_id)
      end

      # Handover is an execute: it changes no consent row, it locks the tablet.
      def audit_action
        action_name == "handover" ? "E" : super
      end

      def fhir_resource_type
        consent_audit_id ? CONSENT_RESOURCE : "Patient"
      end

      def direct_audit_identifier
        consent_audit_id || Patient.canonical_dfn(@dfn) || @dfn
      end

      def consent_audit_id
        @signed_consent.id.to_s if @signed_consent&.persisted?
      end
    end
  end
end
