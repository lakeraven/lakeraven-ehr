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
    # If the request's own audit row then fails, the page says what is in
    # RPMS and that it must not be entered again; the claim was committed on
    # its own, so the form still cannot be replayed. A broker or connection
    # error from the signature check, before any write, means the code could
    # not be checked and nothing was saved. Once a write was sent, anything
    # that raises leaves the outcome unknown: the page says to check the
    # chart, and never shows the raised message, which can carry broker
    # text. A missing RPMS connection after the note was created is an
    # unknown outcome as well; before any write it ends the session
    # (RpmsUserScope). An empty reply to note creation, to its text write or
    # to signing is an unknown outcome too: only a reply that says something
    # is a refusal. The signature code is never rendered back, logged or
    # audited.
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
      # What the audit row says happened to the note. Never the code or the
      # text.
      NOTE_OUTCOME_NOTES = {
        signed: "progress note signed",
        unsigned: "progress note saved unsigned",
        sign_not_permitted: "progress note saved unsigned: TIU did not confirm this user may sign it",
        text_not_written: "progress note text not written",
        not_created: "progress note not created",
        code_not_accepted: "signature code not accepted or not confirmed by RPMS; nothing written",
        code_unchecked: "signature code check failed",
        unknown: "progress note outcome unknown",
        form_token_refused: "progress note form already submitted or expired",
        connection_not_author: "progress note refused: the RPMS connection is not signed on as the author; " \
                               "nothing written",
        no_open_visit: "no open visit found; nothing written",
        visits_unread: "patient visits could not be read; nothing written"
      }.freeze
      # Refusals that end in a 5xx page although nothing was written: the
      # chart did not change, so the audit row is not a serious failure.
      NOTHING_WRITTEN_OUTCOMES = %i[visits_unread].freeze
      # What is in RPMS for each outcome, when the audit row fails after it:
      # :written and :empty (a note without its text) are certain, :maybe is
      # possible.
      WRITE_OUTCOMES = {
        signed: :written, unsigned: :written, sign_not_permitted: :written,
        text_not_written: :empty, unknown: :maybe
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

      # -- Audit failure after an RPC --------------------------------------

      # The shared refusal is right when nothing was sent to TIU. A note
      # that is in RPMS must not be entered again; one that may be there has
      # to be looked for in the chart first.
      def render_unrecorded_access_denial
        case unaudited_write_outcome
        when :written
          log_unaudited_note("recorded in RPMS")
          render plain: unaudited_written_message, status: :service_unavailable
        when :empty
          log_unaudited_note("created without its text")
          render plain: unaudited_empty_message, status: :service_unavailable
        when :maybe
          log_unaudited_note("outcome unknown")
          render plain: unaudited_maybe_message, status: :service_unavailable
        else
          super
        end
      end

      # Nothing reached TIU unless a write was sent.
      def unaudited_write_outcome
        WRITE_OUTCOMES[@note_outcome] if @note_service&.write_sent?
      end

      # Remember the class, then let the concern refuse the access. The
      # message is not logged: it can carry database or broker text.
      def record_audit_event!(detached: false)
        super(detached: detached)
      rescue StandardError => error
        @note_audit_error = error
        raise
      end

      def log_unaudited_note(what)
        Rails.logger.error(
          "ERROR [progress_note] #{what}; this access could not be audited: #{@note_audit_error&.class}"
        )
      end

      def unaudited_written_message
        state = @note_outcome == :signed ? "signed and saved" : "saved unsigned"
        "Service Unavailable: This progress note was #{state} in RPMS, but this access could not be audited. " \
          "It must not be entered again. Check the chart."
      end

      # The note exists: TIU answered its IEN before the text was refused.
      def unaudited_empty_message
        "Service Unavailable: A progress note was created on this visit without its text. " \
          "It was started in RPMS and is unsigned and empty, but this access could not be audited. " \
          "Check the chart before writing it again: a note written now may duplicate it."
      end

      def unaudited_maybe_message
        "Service Unavailable: This progress note may have been saved or signed in RPMS. " \
          "The outcome is unknown, and this access could not be audited. " \
          "Check the chart before writing it again."
      end

      # -- Audit ------------------------------------------------------------

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end

      # An unknown outcome is a serious failure: the chart may have changed.
      # A refusal before any write is not, whatever the page's status.
      def audit_outcome
        return "8" if @note_outcome == :unknown
        return "4" if NOTHING_WRITTEN_OUTCOMES.include?(@note_outcome)

        super
      end

      def audit_outcome_desc
        [ super, NOTE_OUTCOME_NOTES[@note_outcome], filed_note_description ].compact.join("; ").presence
      end

      # The note and the visit a TIU write was sent for, by IEN only.
      def filed_note_description
        return unless @note_service&.write_sent?

        note = canonical_ien(@note_service.created_note_ien)
        visit = canonical_ien(@visit && @visit[:visit_ien])
        [ ("note #{note}" if note), ("on visit #{visit}" if visit) ].compact.join(" ").presence
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
        return render_signature_unchecked if result == :signature_check_raised

        result.success? ? note_signed : render_note_failure(result)
      end

      # The e-signature check and the TIU sequence; nil when the outcome is
      # unknown; :signature_check_raised when the check raised a broker or
      # connection error before any write (nothing was saved). Anything else
      # raised before a write is a fault and goes on. Once a write was sent,
      # anything raised (NotImplementedError too) leaves the chart unknown.
      # A missing RPMS connection goes on to RpmsUserScope until the note is
      # created; after that, the note is in RPMS and its outcome is unknown.
      # Class only in the log line.
      def run_note_sequence(signature_code)
        @note_service = ProgressNoteService.new(
          dfn: @dfn, visit_ien: canonical_ien(@visit[:visit_ien]), author_duz: current_duz
        )
        @note_service.create_and_sign(title_ien: note_title_ien, text: @note_text, signature_code: signature_code)
      rescue ::RpmsRpc::NotConfiguredError => error
        raise if @note_service&.created_note_ien.nil?

        Rails.logger.error("[progress_note] no RPMS connection after the note was created; outcome unknown: " \
                           "#{error.class}")
        nil
      rescue StandardError, NotImplementedError => error
        unless @note_service&.write_sent?
          raise unless UNKNOWN_OUTCOME_ERRORS.any? { |known| error.is_a?(known) }

          Rails.logger.error("[progress_note] signature check raised #{error.class}; nothing written")
          return :signature_check_raised
        end

        Rails.logger.error("[progress_note] create outcome unknown: #{error.class}")
        nil
      end

      def note_signed
        @note_outcome = :signed
        redirect_to patient_chart_path(@dfn), notice: "Progress note signed."
      end

      def render_note_failure(result)
        return render_outcome_unknown if empty_reply?(result)

        case result.stage
        when :signature_check then render_signature_refusal(result)
        when :create then render_not_created
        when :text then render_text_not_written
        when :sign_action then render_sign_not_permitted
        else render_saved_unsigned
        end
      end

      # A note creation, text write or signing that RPMS answered with
      # nothing: it is not a refusal, so the outcome is unknown. A text write
      # refused before it was sent says why (:error), and is a refusal.
      def empty_reply?(result)
        return false unless result.error == :gateway_error && %i[create text sign].include?(result.stage)

        reply = result.raw
        return true unless reply.is_a?(Hash)
        return false if result.stage == :text && reply[:error].present?

        reply[:raw].to_s.strip.empty?
      end

      def render_signature_refusal(result)
        return render_signature_unchecked unless result.error == :invalid_signature_code

        @note_outcome = :code_not_accepted
        render_note_refused("The electronic signature code was not accepted or could not be confirmed by RPMS. " \
                            "Nothing was saved.")
      end

      # RPMS gave no answer to the check (or raised), before anything was
      # written: a refusal, not an unknown outcome.
      def render_signature_unchecked
        @note_outcome = :code_unchecked
        render_note_refused("The electronic signature code could not be checked. Nothing was saved.")
      end

      def render_not_created
        @note_outcome = :not_created
        render_note_refused("The note was not saved. RPMS did not create it.")
      end

      # TIU created the note (it answered its IEN), then refused its text:
      # the note exists, unsigned and empty. The form is not offered again:
      # the chart has to be checked first.
      def render_text_not_written
        @note_outcome = :text_not_written
        @closing_message = "A note was created on this visit without its text. It is in RPMS, unsigned and empty. " \
                           "Check the chart before writing it again."
        render :new, status: :unprocessable_entity
      end

      def render_saved_unsigned
        @note_outcome = :unsigned
        @closing_message = "The note is saved unsigned on this visit. It must be signed."
        render :new, status: :unprocessable_entity
      end

      # TIU did not answer "sign" as the author's action on the note (it
      # answered a cosignature, another action, or nothing, which is also
      # what an empty reply reads as), so the code was not sent.
      def render_sign_not_permitted
        @note_outcome = :sign_not_permitted
        @closing_message = "The note is saved unsigned on this visit. RPMS did not confirm that you may sign it, " \
                           "so it was not signed. Check the chart for who must sign it."
        render :new, status: :unprocessable_entity
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
