# frozen_string_literal: true

module Lakeraven
  module EHR
    # The locked tablet. The patient sees one template, their name, and their
    # date of birth. Staff return by signing on again as the same DUZ.
    class ConsentKioskController < WebController
      include BrowserSmartAuthentication
      include AuditedSessionEnd

      CONSENT_RESOURCE = "Consent"
      layout "lakeraven/ehr/kiosk"

      # Throttled like every credentialed route (#498), by the signed-in
      # session and IP. The signature itself has its own atomic cap of ten
      # refusals per handover; this bounds everything else on the page.
      rate_limit only: %i[show create unlock]

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
        return reject_missing_template! if @template.nil?
        # Token check (and its claim, on a mismatch) before any stored hand-back.
        # A matching token is not claimed, so a correct post after signing still
        # reaches that hand-back uncounted.
        return reject_mismatched_handover_token! unless posted_handover_token_matches?
        return render_stored_signature! if stored_handover_signature
        return refuse_repeated_signature! unless claimed_signature_attempt?

        store_decoded_signature!
      rescue ActiveRecord::RecordInvalid
        note_audit_denial("kiosk signature refused: signature could not be stored")
        render_rejected_signature!
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

      # The lock is keyed by the browser SSO session token. A launched or
      # header bearer has a different id, even when it names the same DUZ.
      def require_clinician_credential!
        return true if kiosk_session_credential?

        render_forbidden("The consent tablet requires a clinician sign-on")
        false
      end

      def kiosk_session_credential?
        current_duz.present? &&
          clinician_credential? &&
          session_access_token&.id == current_token&.id
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

      # The hidden field is this handover. Comparison only. A mismatch is
      # claimed by the refusal below; a match claims nothing.
      def posted_handover_token_matches?
        posted = params[:handover_token]
        expected = @consent_lock["handover_token"].to_s
        return false unless posted.is_a?(String) && expected.present?

        same_secret?(posted, expected)
      end

      def same_secret?(posted, expected)
        posted_bytes = posted.b
        expected_bytes = expected.b
        return false unless posted_bytes.bytesize == expected_bytes.bytesize

        ActiveSupport::SecurityUtils.secure_compare(posted_bytes, expected_bytes)
      end

      # Claim first, then refuse. A non-atomic increment can pass the cap
      # when the in-memory exhaustion check is stale. At the cap this is a
      # 429; a claim that cannot be stored stays closed (503).
      def reject_missing_template!
        return refuse_repeated_signature! unless claimed_signature_attempt?

        note_audit_denial("kiosk signature refused: consent template could not be read")
        render_rejected_signature!
      end

      # A missing or different token never reads a stored hand-back. The claim
      # counts the refusal. A matching token does not enter here.
      def reject_mismatched_handover_token!
        return refuse_repeated_signature! unless claimed_signature_attempt?

        note_audit_denial("kiosk signature refused: handover token mismatch")
        render_rejected_signature!
      end

      def render_rejected_signature!
        @signature_rejected = true
        @signed_consent = nil
        render :show, status: :unprocessable_entity
      end

      # Claims one attempt before the PNG is decoded. A later refusal does not
      # count again. Zero rows (already at the cap) is a 429; a store error
      # stays closed (503) and does not decode.
      def claimed_signature_attempt?
        lock = active_kiosk_lock
        return true if lock.nil?

        lock.claim_signature_attempt!
      rescue StandardError => error
        Rails.logger.error("[consent-kiosk] signature refusal was not counted: #{error.class}")
        @signature_refusal_count_unreadable = true
        false
      end

      def store_decoded_signature!
        unless SignedConsent.acceptable_text?(params[:signer_name])
          note_audit_denial("kiosk signature refused: signer name is not valid text")
          return render_rejected_signature!
        end

        parsed = SignedConsent.decode_signature_data_url(params[:signature])
        unless parsed
          note_audit_denial("kiosk signature refused: signature image is not an acceptable PNG")
          return render_rejected_signature!
        end

        store_posted_signature!(parsed)
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
          signer_name: signer_name_to_store, signature_png: parsed.bytes,
          decoded_signature: parsed, signed_at: Time.current, witness_duz: current_duz,
          kind: SignedConsent::KIND_SIGNATURE, recorded_by_duz: current_duz,
          handover_token: @consent_lock["handover_token"]
        }
      end

      # Blank becomes nil. A non-string is not coerced: the check already
      # refused it, and to_s would store inspect text.
      def signer_name_to_store
        name = params[:signer_name]
        name.presence if name.is_a?(String)
      end

      # A second post of a signature already stored for this handover reads
      # the hand-back page. It must not be audited as another consent create.
      # Only a matching token arrives here, and that post was not claimed.
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

        flash[:consent_handover_ended] = true
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
    end
  end
end
