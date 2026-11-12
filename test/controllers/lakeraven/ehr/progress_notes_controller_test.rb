# frozen_string_literal: true

require "test_helper"
require_relative "../../../dummy/lib/lakeraven_demo_seeds"
require_relative "../../../support/progress_note_test_helper"

module Lakeraven
  module EHR
    # A clinician writes a progress note on an open visit and signs it (#1001).
    # The visit is one check-in made; the note is filed under the site's
    # configured TIU title; the author is the signed-in user.
    class ProgressNotesControllerTest < ActionDispatch::IntegrationTest
      include ProgressNoteTestHelper

      DFN = "3"
      OTHER_DFN = "2"
      CHART = "/lakeraven-ehr/patients/#{DFN}"
      BASE = "/lakeraven-ehr/patients/#{DFN}/notes"
      NEW = "#{BASE}/new"
      LOGIN = "/lakeraven-ehr/login"
      NON_PROVIDER_KEYS = %w[orders_sign orders_enter scheduling_user scheduling_supervisor
                             registration_menu registration_manager].freeze

      setup do
        @forgery_was = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        Lakeraven::EHR::AuditEvent.delete_all
        @demo_original_client = RpmsRpc.configuration.client
        RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
        configure_progress_note_title!(TITLE_IEN)
        @tiu = FakeTiu.new(visits_by_dfn: default_visits)
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @forgery_was
        restore_progress_note_title!
        teardown_oauth!
        Lakeraven::EHR::AuditEvent.delete_all
        if @demo_original_client
          RpmsRpc.configure { |c| c.client = @demo_original_client }
          @demo_original_client = nil
        end
      end

      def default_visits
        {
          DFN => [ open_visit_row, locked_visit_row ],
          OTHER_DFN => [ open_visit_row(visit_ien: OTHER_PATIENT_VISIT_IEN, location: "SYNTHETIC CLINIC C") ]
        }
      end

      def sign_in_provider!(open: DFN)
        sign_in_with_keys!(%w[provider])
        open_patient_context!(open) if open
      end

      def note_params(extra = {})
        { visit_ien: OPEN_VISIT_IEN.to_s, note_text: SYNTHETIC_NOTE_TEXT,
          signature_code: SYNTHETIC_SIGNATURE_CODE }.merge(extra)
      end

      def get_new(tiu = @tiu)
        with_fake_tiu(tiu) { get NEW }
      end

      # A POST carries the one-time token of a form (review round 1). By
      # default the form is fetched first; `form_token:` posts a given token,
      # and nil posts none.
      def post_note(tiu: nil, form_token: :fetch, **extra)
        post_progress_note(BASE, new_path: NEW, dfn: DFN, fake: tiu || @tiu,
                                 params: note_params(extra), form_token: form_token)
      end

      def fetch_form_token = fetch_note_form_token(NEW, dfn: DFN)

      def patient_audit_rows
        AuditEvent.where(entity_type: "Patient", entity_identifier: DFN)
      end

      def assert_outcome_unknown_page!
        assert_response :service_unavailable
        assert_match(/unknown/i, response.body)
        assert_match(/check the chart/i, response.body)
        assert_select "textarea[name=?]", "note_text", count: 0
        assert_select "input[name=?]", "signature_code", count: 0
        refute_includes response.body, SYNTHETIC_BROKER_MESSAGE
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        assert_nil flash[:notice]
      end

      def assert_form_token_refused!(fake)
        assert_includes [ 409, 422 ], response.status
        assert_empty fake.calls, "no RPC: no visit read, no signature check, no TIU call"
        assert_match(/already (been )?submitted|expired/i, response.body)
        assert_match(/check the chart/i, response.body)
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
      end

      def with_broken_audit
        singleton = AuditEvent.singleton_class
        AuditEvent.define_singleton_method(:create!) { |*| raise ActiveRecord::StatementInvalid, "audit down" }
        yield
      ensure
        singleton.send(:remove_method, :create!)
      end

      def assert_refused_before_any_write!(reason)
        assert_response :unprocessable_entity
        assert_match(reason, response.body)
        assert_empty @tiu.write_side_calls, "nothing reaches the e-signature check or TIU"
      end

      def assert_note_form_shown!
        assert_select "form[action=?]", BASE do
          assert_select "textarea[name=?]", "note_text"
          assert_select "input[type=password][name=?]", "signature_code"
        end
      end

      # -- Routes ---------------------------------------------------------------

      test "the note routes are named and take a numeric dfn" do
        helpers = Lakeraven::EHR::Engine.routes.url_helpers

        assert_respond_to helpers, :new_patient_progress_note_path
        assert_respond_to helpers, :patient_progress_notes_path
        assert_equal "/patients/3/notes/new", helpers.new_patient_progress_note_path("3").sub(%r{\A/lakeraven-ehr}, "")
        assert_equal "/patients/3/notes", helpers.patient_progress_notes_path("3").sub(%r{\A/lakeraven-ehr}, "")

        recognized = Lakeraven::EHR::Engine.routes.recognize_path("/patients/3/notes/new", method: :get)
        assert_equal({ controller: "lakeraven/ehr/progress_notes", action: "new", dfn: "3" }, recognized)
        recognized = Lakeraven::EHR::Engine.routes.recognize_path("/patients/3/notes", method: :post)
        assert_equal({ controller: "lakeraven/ehr/progress_notes", action: "create", dfn: "3" }, recognized)
      end

      test "a dfn that is not digits is not a note route" do
        sign_in_provider!
        get_new
        assert_response :ok, "the form answers for a numeric dfn"

        with_fake_tiu(@tiu) { get "/lakeraven-ehr/patients/3x/notes/new" }

        assert_response :not_found
        assert_equal [ [ DFN ] ], @tiu.calls_to(:visits).map { |call| call[1].map(&:to_s) },
                     "visits are read for the numeric dfn only"
      end

      # -- Who may use it -------------------------------------------------------

      test "GET new without a session redirects to the login page and reads nothing" do
        get_new

        assert_redirected_to LOGIN
        assert_empty @tiu.calls
      end

      test "POST without a session redirects to the login page and writes nothing" do
        post_note

        assert_redirected_to LOGIN
        assert_empty @tiu.calls
      end

      test "GET new without the PROVIDER key is forbidden and reads nothing" do
        sign_in_with_keys!(NON_PROVIDER_KEYS)
        open_patient_context!(DFN)

        get_new

        assert_response :forbidden
        assert_empty @tiu.calls
        assert_select "textarea[name=?]", "note_text", count: 0
      end

      test "POST without the PROVIDER key is forbidden and writes nothing" do
        sign_in_with_keys!(NON_PROVIDER_KEYS)
        open_patient_context!(DFN)

        post_note

        assert_response :forbidden
        assert_empty @tiu.calls
      end

      test "GET new for a patient whose record is not open in the session is forbidden" do
        sign_in_provider!(open: OTHER_DFN)

        get_new

        assert_response :forbidden
        assert_select "form[action=?]", "#{CHART}/context"
        assert_select "textarea[name=?]", "note_text", count: 0
        assert_empty @tiu.calls
      end

      test "POST for a patient whose record is not open in the session is forbidden and writes nothing" do
        sign_in_provider!(open: OTHER_DFN)

        post_note

        assert_response :forbidden
        assert_select "form[action=?]", "#{CHART}/context"
        assert_empty @tiu.calls
      end

      test "GET new answers 404 when no note title is configured" do
        sign_in_provider!
        get_new
        assert_response :ok, "available while the title is configured"

        configure_progress_note_title!(nil)
        unconfigured = FakeTiu.new(visits_by_dfn: default_visits)
        get_new(unconfigured)

        assert_response :not_found
        assert_empty unconfigured.calls
      end

      test "POST answers 404 and writes nothing when no note title is configured" do
        sign_in_provider!
        get_new
        assert_response :ok, "available while the title is configured"

        configure_progress_note_title!(nil)
        unconfigured = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: unconfigured)

        assert_response :not_found
        assert_empty unconfigured.calls
      end

      test "POST without a valid CSRF token is refused and writes nothing" do
        sign_in_provider!

        with_fake_tiu(@tiu) { post BASE, params: note_params }
        assert_includes [ 403, 422 ], response.status, "no token"
        assert_empty @tiu.calls

        with_fake_tiu(@tiu) { post BASE, params: note_params.merge(authenticity_token: "forged-token") }
        assert_includes [ 403, 422 ], response.status, "a forged token"
        assert_empty @tiu.calls

        post_note
        assert_redirected_to CHART, "the same post with the session's token is accepted"
      end

      # -- GET new --------------------------------------------------------------

      test "GET new offers each open visit, with its date, time and location, and the note form" do
        sign_in_provider!

        get_new

        assert_response :ok
        assert_equal [ [ DFN ] ], @tiu.calls_to(:visits).map { |call| call[1].map(&:to_s) }.uniq
        assert_empty @tiu.write_side_calls
        assert_note_form_shown!
        assert_select "form[action=?][method=post]", BASE do
          assert_select "input[type=radio][name=?][value=?]", "visit_ien", OPEN_VISIT_IEN.to_s, count: 1
          assert_select "input[type=password][name=?][autocomplete=off]", "signature_code"
        end
        form_text = css_select("form[action='#{BASE}']").text
        assert_includes form_text, OPEN_LOCATION
        assert_match(/2026/, form_text, "the visit's date")
        assert_match(/9:30/, form_text, "the visit's time")
      end

      test "GET new does not offer a locked visit" do
        sign_in_provider!

        get_new

        assert_response :ok
        assert_select "input[name=?]", "visit_ien", count: 1
        assert_select "input[name=?][value=?]", "visit_ien", LOCKED_VISIT_IEN.to_s, count: 0
        refute_includes css_select("form[action='#{BASE}']").text, LOCKED_LOCATION
      end

      test "GET new never carries a signature code value" do
        sign_in_provider!

        get_new

        assert_response :ok
        field = css_select("input[name='signature_code']").first
        assert field, "the signature code field"
        assert field["value"].blank?
      end

      test "GET new with no open visit says so and shows no form" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: { DFN => [ locked_visit_row ] })

        get_new(tiu)

        assert_response :ok
        assert_match(/no open visit/i, response.body)
        assert_match(/check/i, response.body, "check the patient in first")
        assert_select "textarea[name=?]", "note_text", count: 0
        assert_select "input[name=?]", "signature_code", count: 0
        assert_select "input[name=?]", "visit_ien", count: 0
      end

      test "GET new with no visits at all says there is no open visit" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: {})

        get_new(tiu)

        assert_response :ok
        assert_match(/no open visit/i, response.body)
        assert_select "textarea[name=?]", "note_text", count: 0
      end

      test "GET new says visits could not be read when the visit read raises, and shows no form" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: default_visits,
                          raises: { visits: RpmsRpc::Error.new(SYNTHETIC_BROKER_MESSAGE) })

        get_new(tiu)

        refute_equal 500, response.status
        refute_equal 404, response.status
        refute response.redirect?
        assert_match(/visits? could not be read/i, response.body)
        refute_includes response.body, SYNTHETIC_BROKER_MESSAGE
        assert_select "textarea[name=?]", "note_text", count: 0
        assert_select "input[name=?]", "signature_code", count: 0
      end

      # -- POST create: success -------------------------------------------------

      test "POST creates the note on the visit under the configured title, writes its text and signs it" do
        sign_in_provider!

        post_note

        assert_redirected_to CHART
        assert_match(/note/i, flash[:notice].to_s)
        assert_match(/signed/i, flash[:notice].to_s)
        refute_match(/unsigned|not signed/i, flash[:notice].to_s)

        creates = @tiu.calls_to(:create)
        assert_equal 1, creates.size
        assert_equal [ DFN, OPEN_VISIT_IEN.to_s, TITLE_IEN.to_s ], creates.first[1].map(&:to_s)

        texts = @tiu.calls_to(:update_text)
        assert_equal 1, texts.size
        assert_equal NOTE_IEN.to_s, texts.first[1][0].to_s
        assert_equal SYNTHETIC_NOTE_TEXT, texts.first[1][1]

        signs = @tiu.calls_to(:add)
        assert_equal 1, signs.size
        assert_equal [ NOTE_IEN.to_s, DUZ, SYNTHETIC_SIGNATURE_CODE ], signs.first[1].map(&:to_s)
        assert_equal :sign, signs.first[2].fetch(:action, :sign)
      end

      test "POST validates the signature code before the note is created, then creates, writes and signs in order" do
        sign_in_provider!

        post_note

        assert_redirected_to CHART
        names = @tiu.write_side_calls.map(&:first)
        assert_equal :validate, names.first, "the code is checked before anything is written"
        assert_equal %i[create update_text which_action add], names - [ :validate ]
        validation = @tiu.calls_to(:validate).first
        assert_equal [ DUZ, SYNTHETIC_SIGNATURE_CODE ], validation[1].map(&:to_s)
      end

      test "POST re-reads the patient's visits at POST time" do
        sign_in_provider!

        post_note

        assert_redirected_to CHART
        assert_includes @tiu.calls_to(:visits).map { |call| call[1].first.to_s }, DFN
        assert_operator @tiu.names.index(:visits), :<, @tiu.names.index(:create)
      end

      test "POST files the note as the session's user, whatever DUZ the request names" do
        sign_in_provider!

        post_note(author_duz: "777", duz: "777", user_duz: "777")

        assert_redirected_to CHART
        assert_equal [ DUZ ], @tiu.calls_to(:validate).map { |call| call[1][0].to_s }.uniq
        assert_equal [ DUZ ], @tiu.calls_to(:add).map { |call| call[1][1].to_s }
      end

      test "a signed note leaves an audit row for the patient under the acting user" do
        sign_in_provider!
        form_token = fetch_form_token
        AuditEvent.delete_all

        post_note(form_token: form_token)

        assert_redirected_to CHART
        assert AuditEvent.exists?(entity_type: "Patient", entity_identifier: DFN),
               "an AuditEvent row for Patient/#{DFN}"
      end

      # -- POST create: refused before anything is written ----------------------

      test "POST naming a locked visit is refused and nothing is written" do
        sign_in_provider!

        post_note(visit_ien: LOCKED_VISIT_IEN.to_s)

        assert_refused_before_any_write!(/visit/i)
      end

      test "POST naming another patient's open visit is refused and nothing is written" do
        sign_in_provider!

        post_note(visit_ien: OTHER_PATIENT_VISIT_IEN.to_s)

        assert_refused_before_any_write!(/visit/i)
      end

      test "POST naming a visit that does not exist is refused and nothing is written" do
        sign_in_provider!

        post_note(visit_ien: "999999")

        assert_refused_before_any_write!(/visit/i)
      end

      test "POST naming no visit is refused and nothing is written" do
        sign_in_provider!

        post_note(visit_ien: "")

        assert_refused_before_any_write!(/visit/i)
      end

      test "POST is refused when the visit was locked after the form was shown" do
        sign_in_provider!
        get_new
        assert_select "input[name=?][value=?]", "visit_ien", OPEN_VISIT_IEN.to_s

        @tiu = FakeTiu.new(visits_by_dfn: { DFN => [ open_visit_row.merge(locked: true) ] })
        post_note

        assert_refused_before_any_write!(/visit/i)
      end

      test "POST is not a 500 when the visit read raises, and nothing is written" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits,
                           raises: { visits: RpmsRpc::Error.new(SYNTHETIC_BROKER_MESSAGE) })

        post_note

        refute_equal 500, response.status
        refute_equal 404, response.status
        refute response.redirect?
        assert_match(/could not be read|unknown/i, response.body)
        refute_includes response.body, SYNTHETIC_BROKER_MESSAGE
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        assert_empty @tiu.write_side_calls
      end

      test "POST with only whitespace for the note text is refused and nothing is written" do
        sign_in_provider!

        post_note(note_text: " \n\t  ")

        assert_refused_before_any_write!(/note/i)
        assert_note_form_shown!
      end

      test "POST with a blank signature code is refused, nothing is written, and the note text is kept" do
        sign_in_provider!

        post_note(signature_code: "  ")

        assert_refused_before_any_write!(/signature code/i)
        assert_note_form_shown!
        assert_includes css_select("textarea[name='note_text']").text, SYNTHETIC_NOTE_TEXT
      end

      test "POST with a signature code that is not accepted creates no note" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, validate: false)

        post_note

        assert_response :unprocessable_entity
        assert_match(/signature code/i, response.body)
        assert_match(/not accepted/i, response.body)
        assert_equal 1, @tiu.calls_to(:validate).size
        assert_empty @tiu.tiu_calls, "no note is created, written or signed"
        assert_note_form_shown!
        assert_includes css_select("textarea[name='note_text']").text, SYNTHETIC_NOTE_TEXT
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        assert css_select("input[name='signature_code']").first["value"].blank?
      end

      test "POST sends nothing to TIU when the audit log cannot accept a row" do
        sign_in_provider!
        form_token = fetch_form_token
        AuditEvent.delete_all

        with_broken_audit { post_note(form_token: form_token) }

        assert_response :service_unavailable
        assert_empty @tiu.tiu_calls
        assert_equal 0, AuditEvent.count
      end

      # -- POST create: failures once TIU is reached ----------------------------

      test "POST says the note was not saved when TIU refuses to create it, and does not sign" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, create: { success: false, ien: nil, raw: "0^refused" })

        post_note

        assert_response :unprocessable_entity
        assert_match(/not saved/i, response.body)
        assert_equal 1, @tiu.calls_to(:create).size
        assert_empty @tiu.calls_to(:update_text)
        assert_empty @tiu.calls_to(:add)
        assert_includes css_select("textarea[name='note_text']").text, SYNTHETIC_NOTE_TEXT
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
      end

      # Review round 2: the note was created (TIU answered its IEN) before the
      # text was refused, so it exists in RPMS, unsigned and empty. The page
      # says so, as a fact, and no longer says "The note was not saved".
      test "POST says a note was created without its text when its text cannot be written, and does not sign" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, update_text: { success: false, raw: "0" })

        post_note

        assert_response :unprocessable_entity
        refute_match(/not saved/i, response.body)
        assert_match(/note was created on this visit/i, response.body)
        assert_match(/without its text/i, response.body)
        assert_match(/RPMS/, response.body)
        assert_match(/unsigned/i, response.body)
        assert_match(/empty/i, response.body)
        assert_match(/check the chart before writing it again/i, response.body)
        refute_match(/may (or may not )?have been (started|created|saved)/i, response.body,
                     "the note exists: said as a fact, not a possibility")
        assert_select "textarea[name=?]", "note_text", count: 0
        assert_equal 1, @tiu.calls_to(:update_text).size
        assert_empty @tiu.calls_to(:add)
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
      end

      test "POST says the note is saved unsigned and must be signed when signing fails" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, add: { success: false, raw: "89250005^refused" })

        post_note

        assert_response :unprocessable_entity
        assert_equal %i[create update_text add], @tiu.tiu_calls.map(&:first)
        assert_match(/unsigned/i, response.body)
        assert_match(/saved/i, response.body)
        assert_match(/must be signed|needs to be signed|sign it/i, response.body)
        refute_match(/not saved|nothing was saved|was not created/i, response.body)
        refute_match(/note (was |has been )?signed\b/i, response.body)
        assert_nil flash[:notice]
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
      end

      # -- POST create: a gateway raising ---------------------------------------

      # Review round 2: the signature check raising is no longer in this table.
      # Nothing has been sent to TIU at that point, so it is not an unknown
      # write (see "a broker error before any write" below).
      {
        "note creation" => [ :create, -> { RpmsRpc::Error.new(SYNTHETIC_BROKER_MESSAGE) } ],
        "the text write" => [ :update_text, -> { IOError.new(SYNTHETIC_BROKER_MESSAGE) } ],
        "signing" => [ :add, -> { IOError.new(SYNTHETIC_BROKER_MESSAGE) } ]
      }.each do |step, (gateway_call, error)|
        test "POST says the outcome is unknown and to check the chart when #{step} raises" do
          sign_in_provider!
          @tiu = FakeTiu.new(visits_by_dfn: default_visits, raises: { gateway_call => error.call })

          post_note

          refute_equal 500, response.status
          refute_equal 404, response.status
          refute response.redirect?, "an unknown outcome is not reported as a signed note"
          assert_match(/unknown/i, response.body)
          assert_match(/check the chart/i, response.body)
          refute_includes response.body, SYNTHETIC_BROKER_MESSAGE
          refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
          assert_includes @tiu.names, gateway_call
        end
      end

      # -- A broker error before any write is not an unknown write (round 2) ----

      {
        "a broker error" => -> { RpmsRpc::Error.new(SYNTHETIC_BROKER_MESSAGE) },
        "an IOError" => -> { IOError.new(SYNTHETIC_BROKER_MESSAGE) },
        "a connection error" => -> { Errno::ECONNRESET.new(SYNTHETIC_BROKER_MESSAGE) }
      }.each do |label, error|
        test "POST says the signature code could not be checked and nothing was saved when the signature check raises #{label}" do
          sign_in_provider!
          @tiu = FakeTiu.new(visits_by_dfn: default_visits, raises: { validate: error.call })
          form_token = fetch_form_token
          AuditEvent.delete_all

          post_note(form_token: form_token)

          refute_equal 500, response.status
          refute_equal 404, response.status
          refute response.redirect?, "a code that was not checked is not reported as a signed note"
          refute_includes response.body, SYNTHETIC_BROKER_MESSAGE
          refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
          assert_includes @tiu.names, :validate

          assert_includes [ 503, 422 ], response.status
          assert_match(/signature code could not be checked/i, response.body)
          assert_match(/nothing was saved/i, response.body)
          refute_match(/may or may not/i, response.body)
          refute_match(/outcome unknown/i, response.body)
          assert_empty @tiu.tiu_calls, "nothing is sent to TIU"
          assert_nil flash[:notice]

          rows = patient_audit_rows
          assert_operator rows.count, :>, 0, "the refusal is audited"
          refute_includes rows.pluck(:outcome), "8", "not a serious failure: the chart did not change"
          rows.pluck(:outcome_desc).compact.each { |text| refute_match(/outcome unknown/i, text) }
          refute_includes AuditEvent.all.map { |event| event.attributes.to_s }.join, SYNTHETIC_BROKER_MESSAGE
        end
      end

      # -- The signature code stays out of the page, the log and the audit ------

      test "the signature code of a signed note is in no response, log line or audit row" do
        sign_in_provider!
        form_token = fetch_form_token
        AuditEvent.delete_all

        logs = capture_request_logs { post_note(form_token: form_token) }

        assert_redirected_to CHART
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        refute_includes flash.to_hash.to_s, SYNTHETIC_SIGNATURE_CODE
        refute_includes logs, SYNTHETIC_SIGNATURE_CODE
        assert_operator AuditEvent.count, :>, 0
        refute_includes AuditEvent.all.map { |event| event.attributes.to_s }.join, SYNTHETIC_SIGNATURE_CODE
      end

      test "the signature code of a refused note is in no response, log line or audit row" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, validate: false)
        form_token = fetch_form_token
        AuditEvent.delete_all

        logs = capture_request_logs { post_note(form_token: form_token) }

        assert_response :unprocessable_entity
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        refute_includes logs, SYNTHETIC_SIGNATURE_CODE
        refute_includes AuditEvent.all.map { |event| event.attributes.to_s }.join, SYNTHETIC_SIGNATURE_CODE
      end

      # == Review round 1 amendments ============================================

      # -- 1. The audit row fails after TIU was written -------------------------

      {
        "signed" => [ {}, :written ],
        "saved unsigned" => [ { add: { success: false, raw: "89250005^refused" } }, :written ],
        "started but its text was not written" => [ { update_text: { success: false, raw: "0" } }, :maybe ],
        "sent and its outcome is unknown" => [ { raises: { create: RpmsRpc::Error.new(SYNTHETIC_BROKER_MESSAGE) } }, :maybe ]
      }.each do |stage, (fake_options, certainty)|
        test "POST says the note is in RPMS and is not to be entered again when the audit row fails after it was #{stage}" do
          sign_in_provider!
          @tiu = FakeTiu.new(visits_by_dfn: default_visits, **fake_options)
          form_token = fetch_form_token

          with_audit_failing_after_probe { post_note(form_token: form_token) }

          assert_equal 1, @tiu.calls_to(:create).size, "the write was sent: the probe passed"
          assert_response :service_unavailable
          refute_match(/not completed/i, response.body)
          assert_match(/RPMS/, response.body)
          assert_match(/saved|started/i, response.body)
          assert_match(/may /i, response.body, "said as a possibility, not a fact") if certainty == :maybe
          assert_match(/not be (entered|written) again|check the chart/i, response.body)
          refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
          refute_includes response.body, SYNTHETIC_NOTE_TEXT
          refute_includes response.body, SYNTHETIC_BROKER_MESSAGE
          refute_includes response.body, "audit down"
          assert_nil flash[:notice]
        end
      end

      # -- 2. Any exception once a TIU write has been sent ----------------------

      %i[create update_text which_action add].each do |gateway_call|
        { "ArgumentError" => ArgumentError, "NotImplementedError" => NotImplementedError }.each do |label, error_class|
          test "POST says the outcome is unknown, and audits a serious failure, when #{gateway_call} raises #{label}" do
            sign_in_provider!
            @tiu = FakeTiu.new(visits_by_dfn: default_visits,
                               raises: { gateway_call => error_class.new(SYNTHETIC_BROKER_MESSAGE) })
            form_token = fetch_form_token
            AuditEvent.delete_all

            post_note(form_token: form_token)

            assert_includes @tiu.names, gateway_call
            assert_outcome_unknown_page!
            assert_includes patient_audit_rows.pluck(:outcome), "8"
            refute_includes AuditEvent.all.map { |event| event.attributes.to_s }.join, SYNTHETIC_BROKER_MESSAGE
          end
        end
      end

      # -- 3. A session with no RPMS connection of its own ----------------------

      def assert_session_ended_and_sent_to_sign_in!
        assert_redirected_to LOGIN
        assert_match(/sign in/i, flash[:alert].to_s)
        refute_match(/unknown|could not be read/i, response.body)
        get_new(FakeTiu.new(visits_by_dfn: default_visits))
        assert_redirected_to LOGIN, "the session was ended"
      end

      test "GET new ends the session and sends the browser to sign in when the visit read has no RPMS connection" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: default_visits, raises: { visits: RpmsRpc::NotConfiguredError.new("no client") })

        get_new(tiu)

        assert_session_ended_and_sent_to_sign_in!
      end

      test "POST ends the session and sends the browser to sign in when the visit read has no RPMS connection" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, raises: { visits: RpmsRpc::NotConfiguredError.new("no client") })

        post_note

        assert_empty @tiu.write_side_calls
        assert_session_ended_and_sent_to_sign_in!
      end

      test "POST ends the session and sends the browser to sign in when the signature check has no RPMS connection" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits,
                           raises: { validate: RpmsRpc::NotConfiguredError.new("no client") })

        post_note

        assert_empty @tiu.tiu_calls, "no TIU write is attempted"
        assert_session_ended_and_sent_to_sign_in!
      end

      # -- 4. An empty reply is not a definite outcome --------------------------

      test "POST says the outcome is unknown when note creation answers nothing, and not saved only when RPMS refuses it" do
        sign_in_provider!
        refused = FakeTiu.new(visits_by_dfn: default_visits,
                              create: { success: false, ien: 0, raw: "0^title is inactive" })

        post_note(tiu: refused)

        assert_response :unprocessable_entity
        assert_match(/not saved/i, response.body)
        refute_includes response.body, "title is inactive"
        assert_note_form_shown!

        empty = FakeTiu.new(visits_by_dfn: default_visits, create: { success: false, ien: nil, raw: nil })
        form_token = fetch_form_token
        AuditEvent.delete_all

        post_note(tiu: empty, form_token: form_token)

        assert_equal 1, empty.calls_to(:create).size
        assert_empty empty.calls_to(:update_text)
        assert_empty empty.calls_to(:add)
        assert_outcome_unknown_page!
        refute_match(/did not create/i, response.body)
        assert_includes patient_audit_rows.pluck(:outcome), "8"
      end

      test "POST says the outcome is unknown when signing answers nothing, and saved unsigned only when RPMS refuses it" do
        sign_in_provider!
        refused = FakeTiu.new(visits_by_dfn: default_visits, add: { success: false, raw: "89250005^refused" })

        post_note(tiu: refused)

        assert_response :unprocessable_entity
        assert_match(/saved unsigned/i, response.body)
        refute_includes response.body, "89250005"

        empty = FakeTiu.new(visits_by_dfn: default_visits, add: { success: false, raw: nil })
        form_token = fetch_form_token
        AuditEvent.delete_all

        post_note(tiu: empty, form_token: form_token)

        assert_equal 1, empty.calls_to(:add).size
        assert_outcome_unknown_page!
        refute_match(/is saved unsigned/i, response.body)
        assert_includes patient_audit_rows.pluck(:outcome), "8"
      end

      # -- 5. TIU says which signing action the author holds --------------------

      test "POST asks TIU which signing action the author holds on the note, after its text and before signing" do
        sign_in_provider!

        post_note

        assert_redirected_to CHART
        assert_equal %i[validate create update_text which_action add], @tiu.write_side_calls.map(&:first)
        asked = @tiu.calls_to(:which_action)
        assert_equal 1, asked.size
        assert_equal [ NOTE_IEN.to_s, DUZ ], asked.first[1].map(&:to_s)
      end

      { "cosign" => :cosign, "nothing" => nil, "an action that is not sign" => :addend }.each do |label, answer|
        test "POST does not sign, and says RPMS does not let this user sign the note, when TIU answers #{label}" do
          sign_in_provider!
          @tiu = FakeTiu.new(visits_by_dfn: default_visits, which_action: answer)

          post_note

          assert_equal 1, @tiu.calls_to(:which_action).size
          assert_empty @tiu.calls_to(:add), "the code is not sent to sign a note this user may not sign"
          assert_response :unprocessable_entity
          assert_match(/saved unsigned/i, response.body)
          assert_match(/visit/i, response.body)
          assert_match(/RPMS does not (let|allow)/i, response.body)
          refute_match(/not saved|nothing was saved|was not created/i, response.body)
          assert_select "textarea[name=?]", "note_text", count: 0
          assert_nil flash[:notice]
          refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        end
      end

      # -- 6. One submission per form -------------------------------------------

      test "GET new carries a one-time form token in a hidden field of the note form" do
        sign_in_provider!

        get_new

        assert_response :ok
        assert_select "form[action=?] input[type=hidden][name=?]", BASE, FORM_TOKEN_FIELD, count: 1
        assert note_form_token_in_page.present?, "the token has a value"
      end

      test "POST without a form token makes no RPC and says the form was already submitted or has expired" do
        sign_in_provider!

        post_note(form_token: nil)

        assert_form_token_refused!(@tiu)
      end

      test "POST with a form token that was never issued makes no RPC" do
        sign_in_provider!
        fetch_form_token

        post_note(form_token: "SYNTHETIC-UNKNOWN-FORM-TOKEN")

        assert_form_token_refused!(@tiu)
      end

      test "the same form posted twice files one note" do
        sign_in_provider!
        form_token = fetch_form_token
        assert form_token.present?, "the form carries a token"

        post_note(form_token: form_token)
        assert_redirected_to CHART
        assert_equal 1, @tiu.calls_to(:create).size

        again = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: again, form_token: form_token)

        assert_form_token_refused!(again)
      end

      test "a form token is spent even when its POST was refused, and the re-shown form carries a new one" do
        sign_in_provider!
        form_token = fetch_form_token
        assert form_token.present?, "the form carries a token"

        post_note(form_token: form_token, signature_code: "  ")
        assert_refused_before_any_write!(/signature code/i)
        reissued = note_form_token_in_page
        assert reissued.present?, "the form shown again carries a token"
        refute_equal form_token, reissued

        spent = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: spent, form_token: form_token)
        assert_form_token_refused!(spent)

        post_note(form_token: reissued)
        assert_redirected_to CHART
        assert_equal 1, @tiu.calls_to(:create).size
      end

      # -- 7. Open means RPMS said not locked -----------------------------------

      def visit_rows_of_unstated_lock
        [ open_visit_row(visit_ien: 503, location: "SYNTHETIC CLINIC D").merge(locked: nil),
          open_visit_row(visit_ien: 504, location: "SYNTHETIC CLINIC E").except(:locked) ]
      end

      test "GET new does not offer a visit whose lock state RPMS did not state" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: { DFN => [ open_visit_row, *visit_rows_of_unstated_lock ] })

        get_new(tiu)

        assert_response :ok
        assert_select "input[name=?]", "visit_ien", count: 1
        assert_select "input[name=?][value=?]", "visit_ien", OPEN_VISIT_IEN.to_s, count: 1
        refute_includes response.body, "SYNTHETIC CLINIC D"
        refute_includes response.body, "SYNTHETIC CLINIC E"
      end

      test "GET new says there is no open visit when no visit is stated as not locked" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: { DFN => visit_rows_of_unstated_lock })

        get_new(tiu)

        assert_response :ok
        assert_match(/no open visit/i, response.body)
        assert_select "textarea[name=?]", "note_text", count: 0
      end

      %w[503 504].each do |visit_ien|
        test "POST naming visit #{visit_ien}, whose lock state RPMS did not state, is refused and nothing is written" do
          sign_in_provider!
          @tiu = FakeTiu.new(visits_by_dfn: { DFN => [ open_visit_row, *visit_rows_of_unstated_lock ] })

          post_note(visit_ien: visit_ien)

          assert_refused_before_any_write!(/visit/i)
        end
      end

      # -- 8. The audit row names the note and the visit ------------------------

      {
        "signed" => {},
        "saved unsigned" => { add: { success: false, raw: "89250005^refused" } },
        "started but its text was not written" => { update_text: { success: false, raw: "0" } }
      }.each do |stage, fake_options|
        test "the audit row of a note #{stage} names the note and the visit, and never the code or the text" do
          sign_in_provider!
          @tiu = FakeTiu.new(visits_by_dfn: default_visits, **fake_options)
          form_token = fetch_form_token
          AuditEvent.delete_all

          post_note(form_token: form_token)

          refute_equal 500, response.status
          descriptions = patient_audit_rows.pluck(:outcome_desc).compact
          named = descriptions.select { |text| text.match?(/\bnote\D{0,10}#{NOTE_IEN}\b/i) }
          assert_equal 1, named.size, "one audit row names note #{NOTE_IEN}: #{descriptions.inspect}"
          assert_match(/\bvisit\D{0,10}#{OPEN_VISIT_IEN}\b/i, named.first)
          everything = AuditEvent.all.map { |event| event.attributes.to_s }.join
          refute_includes everything, SYNTHETIC_SIGNATURE_CODE
          refute_includes everything, SYNTHETIC_NOTE_TEXT
        end
      end

      # == Review round 2 amendments ============================================

      # -- 9. The form token is spent server-side --------------------------------
      #
      # The browser session is a cookie the client holds. A token struck from
      # the session is back in it when an older cookie is presented, so the
      # claim of a token is recorded in the database (NoteFormClaim). A POST
      # files a note only with a token this session was issued AND that was
      # never claimed before, by any request, under any cookie.

      # The browser's cookies and the CSRF token that goes with them.
      def browser_snapshot
        { cookies: cookies.to_hash.dup, csrf_token: csrf_token }
      end

      # Puts the browser back to a snapshot: every cookie it holds now is
      # dropped and the saved ones are set, so the next request presents the
      # session cookie as it was then.
      def restore_browser!(snapshot)
        forget_browser_cookies!
        snapshot[:cookies].each { |name, value| cookies[name] = value }
        @csrf_token = snapshot[:csrf_token]
        assert_equal snapshot[:cookies], cookies.to_hash, "the saved cookies are the ones the next request sends"
      end

      def forget_browser_cookies!
        cookies.to_hash.each_key { |name| cookies.delete(name) }
        assert_empty cookies.to_hash
      end

      # Every form rendered in the block is given the same token value: the
      # way two sessions come to hold one token. The controller draws its
      # token from SecureRandom.urlsafe_base64.
      def with_form_tokens_all(value)
        SecureRandom.define_singleton_method(:urlsafe_base64) { |*| value }
        yield
      ensure
        SecureRandom.singleton_class.send(:remove_method, :urlsafe_base64)
      end

      def note_form_claims = "Lakeraven::EHR::NoteFormClaim".constantize

      test "a form replayed with the cookie from before its POST makes no RPC and answers 409" do
        sign_in_provider!
        form_token = fetch_form_token
        assert form_token.present?, "the form carries a token"
        before_post = browser_snapshot
        later_token = fetch_form_token
        refute_equal form_token, later_token

        # The restore is real: under the old cookie, a token issued after it
        # was saved is one this session was never issued.
        restore_browser!(before_post)
        never_issued_here = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: never_issued_here, form_token: later_token)
        assert_form_token_refused!(never_issued_here)

        restore_browser!(before_post)
        post_note(form_token: form_token)
        assert_redirected_to CHART
        assert_equal 1, @tiu.calls_to(:create).size

        restore_browser!(before_post)
        replay = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: replay, form_token: form_token)

        assert_empty replay.calls, "no visit read, no signature check, no TIU call"
        assert_response :conflict
        assert_form_token_refused!(replay)
        assert_match(/already (been )?submitted/i, response.body)
        assert_nil flash[:notice]
      end

      test "a form whose POST was refused cannot be replayed with the cookie from before that POST" do
        sign_in_provider!
        form_token = fetch_form_token
        before_post = browser_snapshot

        post_note(form_token: form_token, signature_code: "  ")
        assert_refused_before_any_write!(/signature code/i)

        restore_browser!(before_post)
        replay = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: replay, form_token: form_token)

        assert_empty replay.calls, "no visit read, no signature check, no TIU call"
        assert_response :conflict
        assert_form_token_refused!(replay)
      end

      test "a token claimed in one session cannot be claimed from another session that holds the same token value" do
        same_token = "SYNTHETIC-SAME-FORM-TOKEN-r2"

        sign_in_provider!
        first_token = with_form_tokens_all(same_token) { fetch_form_token }
        first_session = browser_snapshot

        forget_browser_cookies!
        sign_in_provider!
        second_token = with_form_tokens_all(same_token) { fetch_form_token }
        second_session = browser_snapshot

        assert_equal same_token, first_token, "this test fixes the token through SecureRandom.urlsafe_base64"
        assert_equal first_token, second_token, "both sessions were issued the same token value"
        refute_equal first_session[:cookies], second_session[:cookies], "two sessions, two cookies"

        post_note(form_token: second_token)
        assert_redirected_to CHART
        assert_equal 1, @tiu.calls_to(:create).size

        restore_browser!(first_session)
        other = FakeTiu.new(visits_by_dfn: default_visits)
        post_note(tiu: other, form_token: first_token)

        assert_empty other.calls, "no visit read, no signature check, no TIU call"
        assert_response :conflict
        assert_form_token_refused!(other)
      end

      test "a filed note's form token is claimed in the database, and the raw token is not stored" do
        sign_in_provider!
        form_token = fetch_form_token
        claims_before = note_form_claims.count

        post_note(form_token: form_token)

        assert_redirected_to CHART
        assert_equal claims_before + 1, note_form_claims.count, "one claim for the one form"
        stored = note_form_claims.all.map { |claim| claim.attributes.values.join(" ") }.join(" ")
        refute_includes stored, form_token
      end

      test "a refused POST claims its form token in the database too" do
        sign_in_provider!
        form_token = fetch_form_token
        claims_before = note_form_claims.count

        post_note(form_token: form_token, signature_code: "  ")

        assert_refused_before_any_write!(/signature code/i)
        assert_equal claims_before + 1, note_form_claims.count
      end
    end
  end
end
