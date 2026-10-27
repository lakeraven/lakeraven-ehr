# frozen_string_literal: true

module Lakeraven
  module EHR
    # Server-rendered allergy entry from the chart (#644).
    #
    # Same credential as the chart and the screening surface: a SMART token,
    # its scopes, and a clinician DUZ, plus the session's deliberate patient
    # context. The originator filed with the allergy is that DUZ. A request
    # parameter cannot name someone else.
    #
    # An allergy write is an RPC. It cannot join the audit transaction, so a
    # failed audit cannot undo it. The action proves the audit insert works
    # and rolls that proof back before calling the gateway. The row that
    # remains is the one AuditableClinicalAccess writes after the response
    # status is known. If the proof insert fails, the gateway is not called.
    class AllergiesController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext

      ALLERGY_RESOURCE = "AllergyIntolerance"
      USER_CONTEXTS = %w[user].freeze
      SCALAR_FIELDS = %i[
        agent agent_pointer type nature originated_at
        observed_or_historical reaction_date severity
      ].freeze

      before_action :authenticate_smart_token!
      before_action :authorize_allergy_scope!
      # Forgery protection runs before authentication and raises. A browser
      # with no credential gets the same 401 as any other anonymous write;
      # a signed-in browser keeps the cross-site refusal.
      rescue_from ActionController::InvalidAuthenticityToken, with: :reject_forged_allergy_write
      before_action :require_clinician_credential!, only: %i[create no_known_allergies]
      before_action :load_patient
      before_action :enforce_token_patient_context!
      before_action :enforce_patient_context!

      def new
        @allergy = {}
      end

      def create
        return if audit_unwritable?

        @allergy = permitted_allergy
        if allergy_recorded?
          redirect_to patient_chart_path(@dfn), notice: "Allergy recorded."
        else
          @allergy_not_saved = true
          render :new, status: :unprocessable_entity
        end
      end

      def no_known_allergies
        return if audit_unwritable?

        if nka_recorded?
          redirect_to patient_chart_path(@dfn), notice: "No known allergies recorded."
        else
          render :no_known_allergies, status: :unprocessable_entity
        end
      end

      private

      helper_method :allergy_value, :symptom_value, :comment_value

      def authorize_allergy_scope!
        return true if allergy_scope_permitted?

        verb = request.get? ? "read" : "record"
        render_forbidden("Insufficient scope to #{verb} #{ALLERGY_RESOURCE}")
        false
      end

      def allergy_scope_permitted?
        if request.get?
          can_read?(ALLERGY_RESOURCE)
        else
          scope_permits?(ALLERGY_RESOURCE, write_permission, contexts: USER_CONTEXTS)
        end
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      def require_clinician_credential!
        return true if current_duz.present?

        render_forbidden("Recording an allergy requires a clinician sign-on")
        false
      end

      def load_patient
        @dfn = params[:dfn]
      end

      def reject_forged_allergy_write
        if session[:smart_token].present?
          head :unprocessable_entity
        else
          render_unauthorized("No Bearer token provided")
        end
      end

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      # The proof row is rolled back. A raised insert means the log cannot
      # record this access, so the RPC must not run.
      def audit_unwritable?
        return false if audit_log_writable?

        render_unrecorded_access_denial
        true
      end

      def audit_log_writable?
        AuditEvent.transaction(requires_new: true) do
          AuditEvent.create!(probe_audit_attributes)
          raise ActiveRecord::Rollback
        end
        true
      rescue StandardError => error
        Rails.logger.warn("[allergy] audit log did not accept a row: #{error.class}")
        false
      end

      def probe_audit_attributes
        {
          event_type: "rest",
          action: "C",
          outcome: "0",
          entity_type: "Patient",
          entity_identifier: Patient.canonical_dfn(@dfn) || @dfn.to_s
        }
      end

      def allergy_recorded?
        gateway_succeeded?(
          AllergyIntoleranceGateway.add(@dfn, allergy_for_gateway, clinician_duz: current_duz)
        )
      end

      def nka_recorded?
        gateway_succeeded?(AllergyIntoleranceGateway.record_no_known_allergies(@dfn))
      end

      def gateway_succeeded?(result)
        result.is_a?(Hash) && result[:success] == true
      end

      # originator is intentionally absent. The gateway files the DUZ.
      def permitted_allergy
        raw = params[:allergy]
        return {} unless raw.respond_to?(:permit)

        raw.permit(SCALAR_FIELDS, comments: [], symptoms: %i[ien text date]).to_h
      end

      def allergy_for_gateway
        attrs = permitted_allergy
        attrs.merge(
          "symptoms" => present_symptoms(attrs["symptoms"]),
          "comments" => present_comments(attrs["comments"])
        )
      end

      def present_symptoms(rows)
        Array(rows).select { |row| row.is_a?(Hash) && row.values.any? { |value| value.to_s.strip.present? } }
      end

      def present_comments(lines)
        Array(lines).map(&:to_s).reject(&:blank?)
      end

      def allergy_value(key)
        record = @allergy || {}
        record[key.to_s] || record[key.to_sym]
      end

      def symptom_value(key)
        row = Array(allergy_value("symptoms")).first
        return if row.blank?

        row[key.to_s] || row[key.to_sym]
      end

      def comment_value
        Array(allergy_value("comments")).first
      end
    end
  end
end
