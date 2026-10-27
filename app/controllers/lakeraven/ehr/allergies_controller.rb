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
    # If the RPC succeeded and that later row fails, the response says the
    # write is already in RPMS and must not be entered again.
    class AllergiesController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext

      ALLERGY_RESOURCE = "AllergyIntolerance"
      USER_CONTEXTS = %w[user].freeze
      SCALAR_FIELDS = %i[
        agent agent_pointer type nature originated_at
        observed_or_historical reaction_date severity
      ].freeze
      SYMPTOM_FIELDS = %w[ien text date].freeze
      # A backend error symbol is safe to keep. Free text is not.
      SAFE_GATEWAY_ERROR = /\A[a-z][a-z0-9_]*\z/
      INDEX_KEY = /\A-?\d+\z/

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
        return render_allergy_not_saved unless allergy_lists_well_formed?

        @allergy = permitted_allergy
        if allergy_recorded?
          redirect_to patient_chart_path(@dfn), notice: "Allergy recorded."
        else
          render_allergy_not_saved
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
      helper_method :allergy_failure_heading, :allergy_failure_detail
      helper_method :nka_failure_heading, :nka_failure_detail

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

      # Remember the class, then let the concern refuse the access. The
      # message is not logged: it can carry the broker's own text.
      def record_audit_event!(detached: false)
        super(detached: detached)
      rescue StandardError => error
        @rpms_audit_error = error
        raise
      end

      # The concern says the access was not completed. That is true only
      # when the RPC did not run. A committed write must not be entered again.
      def render_unrecorded_access_denial
        return super unless @rpms_write

        log_unaudited_rpms_write
        render plain: unaudited_rpms_message, status: :service_unavailable
      end

      def log_unaudited_rpms_write
        Rails.logger.error(
          "ERROR [allergy] #{action_name} recorded in RPMS but this access could not be audited: " \
          "#{@rpms_audit_error&.class}"
        )
      end

      def unaudited_rpms_message
        subject = @rpms_write == :nka ? "No known allergies were" : "This allergy was"
        "Service Unavailable: #{subject} recorded in RPMS, but this access could not be audited. " \
          "It must not be entered again."
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
        result = AllergyIntoleranceGateway.add(@dfn, allergy_for_gateway, clinician_duz: current_duz)
        note_gateway_result(:allergy, result)
      end

      def nka_recorded?
        result = AllergyIntoleranceGateway.record_no_known_allergies(@dfn)
        note_gateway_result(:nka, result)
      end

      def note_gateway_result(kind, result)
        if gateway_succeeded?(result)
          @rpms_write = kind
          true
        else
          @allergy_error = safe_gateway_error(result)
          false
        end
      end

      def gateway_succeeded?(result)
        result.is_a?(Hash) && result[:success] == true
      end

      # Only the symbol. The backend's message text is never kept.
      def safe_gateway_error(result)
        error = result[:error] if result.is_a?(Hash)
        error if error.is_a?(Symbol) && error.name.match?(SAFE_GATEWAY_ERROR)
      end

      def render_allergy_not_saved
        @allergy ||= permitted_allergy
        @allergy_not_saved = true
        render :new, status: :unprocessable_entity
      end

      # originator is intentionally absent. The gateway files the DUZ.
      # Symptoms and comments arrive as arrays or as Rails' indexed hashes.
      def permitted_allergy
        permitted_scalars.merge(
          "symptoms" => symptom_rows.map { |row| symptom_fields(row) },
          "comments" => comment_lines
        )
      end

      def permitted_scalars
        raw = params[:allergy]
        return {} unless raw.respond_to?(:permit)

        raw.permit(SCALAR_FIELDS).to_h
      end

      def allergy_for_gateway
        attrs = permitted_allergy
        attrs.merge(
          "symptoms" => present_symptoms(attrs["symptoms"]),
          "comments" => present_comments(attrs["comments"])
        )
      end

      # A string, or any hash that is not index => row, is refused before
      # the gateway so a bad encoding cannot be written.
      def allergy_lists_well_formed?
        list_well_formed?(:symptoms, :hash) && list_well_formed?(:comments, :scalar)
      end

      def list_well_formed?(key, entry_kind)
        value = allergy_param(key)
        return true if value.nil? || value.is_a?(Array)
        return false unless hash_param?(value)

        hash_entries(value).all? { |index, entry| entry_well_formed?(index, entry, entry_kind) }
      end

      def entry_well_formed?(index, entry, entry_kind)
        return false unless index_key?(index)

        entry_kind == :hash ? hash_param?(entry) : entry.is_a?(String)
      end

      def allergy_param(key)
        raw = params[:allergy]
        raw[key] if raw.respond_to?(:key?)
      end

      def symptom_rows
        collection_rows(allergy_param(:symptoms))
      end

      def comment_lines
        collection_rows(allergy_param(:comments)).select { |line| comment_scalar?(line) }
      end

      def collection_rows(value)
        return [] if value.nil?
        return value if value.is_a?(Array)
        return indexed_rows(value) if hash_param?(value)

        []
      end

      def indexed_rows(value)
        hash_entries(value)
          .select { |key, _| index_key?(key) }
          .sort_by { |key, _| Integer(key.to_s) }
          .map(&:last)
      end

      def hash_entries(value)
        value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : value.to_h
      end

      def symptom_fields(row)
        symptom_parameters(row).permit(*SYMPTOM_FIELDS).to_h
      end

      def symptom_parameters(row)
        return row if row.is_a?(ActionController::Parameters)
        return ActionController::Parameters.new(row) if row.is_a?(Hash)

        ActionController::Parameters.new
      end

      def hash_param?(value)
        value.is_a?(Hash) || value.is_a?(ActionController::Parameters)
      end

      def index_key?(key)
        key.to_s.match?(INDEX_KEY)
      end

      def comment_scalar?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value.nil? || value == true || value == false
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

      def allergy_failure_heading
        case @allergy_error
        when :duplicate then "Already on file"
        when :unavailable then "Outcome unknown"
        when :active_allergies then "Active allergies on file"
        else "This allergy was not saved"
        end
      end

      def allergy_failure_detail
        case @allergy_error
        when :duplicate then "This allergy is already on file."
        when :unavailable then "The outcome is unknown. Check the chart before trying again."
        when :active_allergies then "The patient has active allergies on file."
        else "The allergy was not saved."
        end
      end

      def nka_failure_heading
        case @allergy_error
        when :active_allergies then "Active allergies on file"
        when :unavailable then "Outcome unknown"
        else "Not saved"
        end
      end

      def nka_failure_detail
        case @allergy_error
        when :active_allergies then "The patient has active allergies on file."
        when :duplicate then "This is already on file."
        when :unavailable then "The outcome is unknown. Check the chart before trying again."
        else "This was not saved."
        end
      end
    end
  end
end
