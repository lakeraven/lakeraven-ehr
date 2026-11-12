# frozen_string_literal: true

module Lakeraven
  module EHR
    # A progress note written on an open visit from the chart, and signed
    # with the author's electronic signature code (#1001).
    #
    # The author is the signed-in user: the DUZ of the session's own sign-on
    # credential. A request parameter cannot name someone else. Writing a
    # note takes the PROVIDER key (Capabilities "progress_note.write") and
    # the site's note title (Configuration#progress_note_title_ien); without
    # a title the form does not exist.
    #
    # The POST re-reads the patient's visits and files the note only on one
    # of that patient's open visits. The signature code is checked with RPMS
    # before anything is written, so a code RPMS does not accept creates no
    # note. Then the note is created, its text written, and it is signed.
    #
    # A TIU write is an RPC. It cannot join the audit transaction, so the
    # action proves the audit log takes a row before any RPC (AuditLogProbe).
    # An RPC that raises leaves the outcome unknown: the page says to check
    # the chart, and never shows the raised message, which can carry broker
    # text. The signature code is never rendered back, logged or audited.
    class ProgressNotesController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext
      include AuditLogProbe

      CAPABILITY = "progress_note.write"
      # The failures that leave the outcome of a TIU or e-signature RPC
      # unknown: the broker raised, or the connection did.
      UNKNOWN_OUTCOME_ERRORS = [ ::RpmsRpc::Error, IOError, SystemCallError ].freeze
      IEN_FORMAT = /\A[0-9]+\z/
      # What the audit row says happened to the note. Never the code.
      NOTE_OUTCOME_NOTES = {
        signed: "progress note signed",
        unsigned: "progress note saved unsigned",
        text_not_written: "progress note text not written",
        not_created: "progress note not created",
        code_not_accepted: "signature code not accepted",
        code_unchecked: "signature code check failed",
        unknown: "progress note outcome unknown"
      }.freeze

      rate_limit only: %i[new create]

      # Forgery protection runs first and raises. A signed-in browser gets
      # the cross-site refusal; a browser with no session goes to sign in.
      rescue_from ActionController::InvalidAuthenticityToken, with: :reject_forged_note
      before_action :require_authentication
      before_action :authenticate_smart_token!
      before_action -> { require_capability!(CAPABILITY) }
      before_action :require_note_title!
      before_action :load_patient
      before_action :enforce_token_patient_context!
      before_action :enforce_patient_context!
      before_action :require_clinician_credential!

      def new
        @note_text = ""
        @open_visits = read_open_visits
      end

      def create
        return if audit_unwritable?

        @note_text = string_param(:note_text)
        @open_visits = read_open_visits
        return render_visits_unread if @open_visits.nil?

        refusal = input_refusal
        return render_note_refused(refusal) if refusal

        file_note(params_signature_code)
      end

      private

      helper_method :visit_label, :selected_visit_ien

      # -- Gates ------------------------------------------------------------

      def require_note_title!
        return if note_title_ien

        note_audit_denial("browser access refused: no progress note title configured")
        render plain: "Not Found", status: :not_found
      end

      def note_title_ien = Lakeraven::EHR.configuration.progress_note_title_ien

      def load_patient
        @dfn = params[:dfn]
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      # The author is the sign-on credential's own DUZ, and it must be the
      # session's: the two are minted together, so a difference is refused.
      def require_clinician_credential!
        duz = current_duz
        return true if duz.present? && duz.to_s == session[:duz].to_s

        render_forbidden("Writing a progress note requires a clinician sign-on")
        false
      end

      def reject_forged_note
        if session[:duz].present?
          head :unprocessable_entity
        else
          redirect_to login_path, alert: "Please sign in"
        end
      end

      def audit_unwritable?
        return false if audit_log_writable?

        render_unrecorded_access_denial
        true
      end

      def audit_probe_log_tag = "progress_note"
      def audit_probe_dfn = @dfn

      # -- Audit ------------------------------------------------------------

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      # An unknown outcome is a serious failure: the chart may have changed.
      def audit_outcome
        return "8" if @note_outcome == :unknown

        super
      end

      def audit_outcome_desc
        [ super, NOTE_OUTCOME_NOTES[@note_outcome] ].compact.join("; ").presence
      end

      # -- Visits -----------------------------------------------------------

      # The patient's open visits, as RPMS reports them now, or nil when they
      # could not be read. A visit is open unless it is locked.
      def read_open_visits
        rows = EncounterGateway.visits(@dfn)
        Array(rows).select { |row| row.is_a?(Hash) && !row[:locked] && canonical_ien(row[:visit_ien]) }
      rescue *UNKNOWN_OUTCOME_ERRORS => error
        Rails.logger.error("[progress_note] visit read raised #{error.class}")
        nil
      end

      def chosen_visit
        posted = canonical_ien(params[:visit_ien])
        return unless posted

        @open_visits.find { |row| canonical_ien(row[:visit_ien]) == posted }
      end

      # A positive integer, as a string without leading zeros, or nil.
      def canonical_ien(value)
        text = value.to_s
        return unless value.is_a?(String) || value.is_a?(Integer)
        return unless text.match?(IEN_FORMAT)

        ien = Integer(text, 10)
        ien.to_s if ien.positive?
      end

      def selected_visit_ien
        canonical_ien(params[:visit_ien]) if request.post?
      end

      def visit_label(row)
        when_seen = row[:datetime]
        stamp = when_seen.respond_to?(:strftime) ? when_seen.strftime("%b %-d, %Y %-l:%M %p") : when_seen.to_s
        [ stamp.presence, row[:location].to_s.presence || "Unknown location" ].compact.join(" · ")
      end

      # -- Input ------------------------------------------------------------

      def string_param(key)
        value = params[key]
        value.is_a?(String) ? value : ""
      end

      def params_signature_code = string_param(:signature_code)

      def input_refusal
        @visit = chosen_visit
        return "Choose one of this patient's open visits for the note." unless @visit
        return "Write the note before signing it." if @note_text.strip.empty?
        return "Enter your electronic signature code to sign the note." if params_signature_code.strip.empty?

        nil
      end

      # -- Filing -----------------------------------------------------------

      def file_note(signature_code)
        result = note_service.create_and_sign(
          title_ien: note_title_ien, text: @note_text, signature_code: signature_code
        )
        result.success? ? note_signed : render_note_failure(result)
      rescue *UNKNOWN_OUTCOME_ERRORS => error
        Rails.logger.error("[progress_note] create outcome unknown: #{error.class}")
        render_outcome_unknown
      end

      def note_service
        ProgressNoteService.new(dfn: @dfn, visit_ien: canonical_ien(@visit[:visit_ien]), author_duz: current_duz)
      end

      def note_signed
        @note_outcome = :signed
        redirect_to patient_chart_path(@dfn), notice: "Progress note signed."
      end

      def render_note_failure(result)
        case result.stage
        when :signature_check then render_signature_refusal(result)
        when :create then render_not_created
        when :text then render_text_not_written
        else render_saved_unsigned
        end
      end

      def render_signature_refusal(result)
        if result.error == :invalid_signature_code
          @note_outcome = :code_not_accepted
          render_note_refused("The electronic signature code was not accepted. Nothing was saved.")
        else
          @note_outcome = :code_unchecked
          render_note_refused("The electronic signature code could not be checked. Nothing was saved.")
        end
      end

      def render_not_created
        @note_outcome = :not_created
        render_note_refused("The note was not saved. RPMS did not create it.")
      end

      # The note may exist without its text. The form is not offered again:
      # the chart has to be checked first.
      def render_text_not_written
        @note_outcome = :text_not_written
        @closing_message = "The note was not saved: its text could not be written. " \
                           "An empty note may have been started on this visit. Check the chart before writing it again."
        render :new, status: :unprocessable_entity
      end

      def render_saved_unsigned
        @note_outcome = :unsigned
        @closing_message = "The note is saved unsigned on this visit. It must be signed."
        render :new, status: :unprocessable_entity
      end

      def render_outcome_unknown
        @note_outcome = :unknown
        @closing_message = "Outcome unknown — check the chart before trying again. " \
                           "The note may or may not have been saved or signed."
        render :new, status: :service_unavailable
      end

      def render_visits_unread
        render :new, status: :service_unavailable
      end

      def render_note_refused(message)
        @refusal = message
        render :new, status: :unprocessable_entity
      end
    end
  end
end
