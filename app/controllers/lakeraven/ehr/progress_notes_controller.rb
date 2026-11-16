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
    # Each rendered form carries a one-time token. The session lists the
    # last few tokens it was given, per patient, and a POST must bring one of
    # them. The token is then claimed in the database (NoteFormClaim) before
    # any RPC, whatever happens next: the session is a cookie the client
    # holds, so an older copy of it still lists the token, but a claim is
    # made once, by one request, under any cookie. A token that was not
    # issued to this session, or was claimed before, is refused with 409.
    #
    # The POST re-reads the patient's visits and files the note only on one
    # of that patient's open visits: a visit RPMS reports as not locked
    # (locked: false). An empty visit list is also what an empty broker reply
    # reads as, so the page says only that no open visit was found.
    #
    # TIU and the e-signature check take the author and the signer from the
    # RPMS connection's own DUZ, never from a parameter. So before the code
    # is checked or anything is written, the request's connection
    # (RpmsRpc.client) must report the author's DUZ; a connection signed on
    # as nobody, as someone else, or that cannot say, is refused (403) and
    # nothing is sent. The visit read is not gated.
    #
    # The signature code is checked with RPMS before anything is written,
    # so a code RPMS does not accept (or answers false for) creates no note.
    # Then the note is created and its text written. TIU is asked which
    # signing action the author holds on the note, and only "sign" signs it;
    # any other answer, none included, leaves it saved unsigned.
    #
    # A TIU write is an RPC. It cannot join the audit transaction, so the
    # action proves the audit log takes a row before any RPC (AuditLogProbe).
    # Anything raised while the note is filed leaves the outcome unknown: the
    # page says to check the chart, and never shows the raised message, which
    # can carry broker text. The signature code is never rendered back.
    class ProgressNotesController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext
      include AuditLogProbe

      CAPABILITY = "progress_note.write"
      # The failures that leave the outcome of a TIU or e-signature RPC
      # unknown: the broker raised, or the connection did.
      UNKNOWN_OUTCOME_ERRORS = [ ::RpmsRpc::Error, IOError, SystemCallError ].freeze
      IEN_FORMAT = /\A[0-9]+\z/
      # The form tokens issued to this session, as "dfn:token", at most this
      # many at once (the oldest is dropped). Whether a token was spent is in
      # NoteFormClaim, not here.
      FORM_TOKEN_SESSION_KEY = :progress_note_form_tokens
      FORM_TOKEN_FIELD = "note_form_token"
      FORM_TOKEN_LIMIT = 5

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
        return render_form_token_refused unless form_token_issued?
        return if audit_unwritable?
        return render_form_token_refused unless NoteFormClaim.claim!(params[FORM_TOKEN_FIELD])

        @note_text = string_param(:note_text)
        @open_visits = read_open_visits
        return render_visits_unread if @open_visits.nil?
        return render_connection_not_author unless connection_signed_on_as_author?
        return render_no_open_visit if @open_visits.empty?

        refusal = input_refusal
        return render_note_refused(refusal) if refusal

        file_note(params_signature_code)
      end

      private

      helper_method :visit_label, :selected_visit_ien, :note_form_token

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

      # -- One-time form token ---------------------------------------------

      # The token of the form this response renders, issued once per
      # response and kept in the session for this patient.
      def note_form_token
        @note_form_token ||= issue_form_token
      end

      def issue_form_token
        token = SecureRandom.urlsafe_base64(24)
        entries = stored_form_tokens.push(form_token_entry(token))
        session[FORM_TOKEN_SESSION_KEY] = entries.last(FORM_TOKEN_LIMIT)
        token
      end

      # Whether the posted token is one this session was given for this
      # patient. Whether it was already spent is the claim's to say.
      def form_token_issued?
        posted = params[FORM_TOKEN_FIELD]
        return false unless posted.is_a?(String) && posted.present?

        wanted = form_token_entry(posted)
        stored_form_tokens.any? { |entry| ActiveSupport::SecurityUtils.secure_compare(entry, wanted) }
      end

      def stored_form_tokens
        Array(session[FORM_TOKEN_SESSION_KEY]).grep(String)
      end

      def form_token_entry(token) = "#{@dfn}:#{token}"

      def render_form_token_refused
        @note_outcome = :form_token_refused
        note_audit_denial("progress note form token refused")
        @closing_message = "This form was already submitted or has expired. This submission sent nothing to RPMS, " \
                           "but an earlier submission of this form may have filed the note. " \
                           "Check the chart before writing the note again."
        render :new, status: :conflict
      end

      # -- Audit ------------------------------------------------------------

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      # -- The RPMS connection's user ---------------------------------------

      # Whether the request's RPMS connection reports the author's DUZ. TIU
      # and the e-signature check sign as that connection's user, so a note
      # filed on any other connection would not be the author's. A request
      # with no RPMS connection of its own goes on to RpmsUserScope; anything
      # else raised while asking is not a confirmation. Class only in the log.
      def connection_signed_on_as_author?
        client = ::RpmsRpc.client
        return false unless client.respond_to?(:duz)

        connected = canonical_ien(client.duz)
        !connected.nil? && connected == canonical_ien(current_duz)
      rescue ::RpmsRpc::NotConfiguredError
        raise
      rescue StandardError => error
        Rails.logger.error("[progress_note] RPMS connection user could not be read: #{error.class}")
        false
      end

      def render_connection_not_author
        @note_outcome = :connection_not_author
        @closing_message = "This note cannot be filed: the RPMS connection is not signed on as you. " \
                           "Nothing was saved. Sign in again, then write the note."
        render :new, status: :forbidden
      end

      # -- Visits -----------------------------------------------------------

      # The patient's open visits, as RPMS reports them now, or nil when they
      # could not be read. A visit is open only when RPMS says it is not
      # locked (locked: false); an unstated lock state is not open. A request
      # with no RPMS connection of its own goes on to RpmsUserScope.
      def read_open_visits
        rows = EncounterGateway.visits(@dfn)
        Array(rows).select { |row| row.is_a?(Hash) && row[:locked] == false && canonical_ien(row[:visit_ien]) }
      rescue ::RpmsRpc::NotConfiguredError
        raise
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
        result = run_note_sequence(signature_code)
        return render_outcome_unknown if result.nil?

        result.success? ? note_signed : render_note_failure(result)
      end

      # The e-signature check and the TIU sequence; nil when the outcome is
      # unknown: anything raised leaves the chart unknown. Class only in the
      # log line.
      def run_note_sequence(signature_code)
        @note_service = ProgressNoteService.new(
          dfn: @dfn, visit_ien: canonical_ien(@visit[:visit_ien]), author_duz: current_duz
        )
        @note_service.create_and_sign(title_ien: note_title_ien, text: @note_text, signature_code: signature_code)
      rescue StandardError, NotImplementedError => error
        Rails.logger.error("[progress_note] create outcome unknown: #{error.class}")
        nil
      end

      def note_signed
        @note_outcome = :signed
        redirect_to patient_chart_path(@dfn), notice: "Progress note signed."
      end

      # A refusal of the signature code says so. Any other failure is
      # reported as an unknown outcome until each step's page says what RPMS
      # established.
      def render_note_failure(result)
        return render_signature_refusal(result) if result.stage == :signature_check

        render_outcome_unknown
      end

      def render_signature_refusal(result)
        return render_signature_unchecked unless result.error == :invalid_signature_code

        @note_outcome = :code_not_accepted
        render_note_refused("The electronic signature code was not accepted or could not be confirmed by RPMS. " \
                            "Nothing was saved.")
      end

      # RPMS gave no answer to the check, before anything was written: a
      # refusal, not an unknown outcome.
      def render_signature_unchecked
        @note_outcome = :code_unchecked
        render_note_refused("The electronic signature code could not be checked. Nothing was saved.")
      end

      def render_outcome_unknown
        @note_outcome = :unknown
        @closing_message = "Outcome unknown — check the chart before trying again. " \
                           "The note may or may not have been saved or signed."
        render :new, status: :service_unavailable
      end

      def render_visits_unread
        @note_outcome = :visits_unread
        render :new, status: :service_unavailable
      end

      # RPMS listed no open visit: none was found, which an empty reply
      # also reads as. The view says so and offers no form.
      def render_no_open_visit
        @note_outcome = :no_open_visit
        render :new, status: :unprocessable_entity
      end

      def render_note_refused(message)
        @refusal = message
        render :new, status: :unprocessable_entity
      end
    end
  end
end
