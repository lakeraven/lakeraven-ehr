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
    # last few tokens it was given, per patient.
    #
    # The form offers only the patient's open visits: a visit RPMS reports as
    # not locked (locked: false). An empty visit list is also what an empty
    # broker reply reads as, so the page says only that no open visit was
    # found.
    class ProgressNotesController < WebController
      include BrowserSmartAuthentication
      include ClinicianPatientContext

      CAPABILITY = "progress_note.write"
      # The failures that leave the outcome of a TIU or e-signature RPC
      # unknown: the broker raised, or the connection did.
      UNKNOWN_OUTCOME_ERRORS = [ ::RpmsRpc::Error, IOError, SystemCallError ].freeze
      IEN_FORMAT = /\A[0-9]+\z/
      # The form tokens issued to this session, as "dfn:token", at most this
      # many at once (the oldest is dropped). Whether a token was spent is in
      # NoteFormClaim, not here.
      FORM_TOKEN_SESSION_KEY = :progress_note_form_tokens
      FORM_TOKEN_LIMIT = 5

      rate_limit only: %i[new create]

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

      # Filing arrives with the next slice of #1001. Until then a POST that
      # passes the form's gates is answered as not found and sends nothing.
      def create
        head :not_found
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

      def stored_form_tokens
        Array(session[FORM_TOKEN_SESSION_KEY]).grep(String)
      end

      def form_token_entry(token) = "#{@dfn}:#{token}"

      # -- Audit ------------------------------------------------------------

      def fhir_resource_type = "Patient"

      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
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
    end
  end
end
