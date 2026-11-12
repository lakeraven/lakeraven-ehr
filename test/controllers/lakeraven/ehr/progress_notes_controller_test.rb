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

      def post_note(tiu: nil, **extra)
        with_fake_tiu(tiu || @tiu) { post BASE, params: note_params(extra).merge(authenticity_token: csrf_token) }
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
        assert_equal %i[create update_text add], names - [ :validate ]
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
        AuditEvent.delete_all

        post_note

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
        AuditEvent.delete_all

        with_broken_audit { post_note }

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

      test "POST says the note was not saved when its text cannot be written, and does not sign" do
        sign_in_provider!
        @tiu = FakeTiu.new(visits_by_dfn: default_visits, update_text: { success: false, raw: "0" })

        post_note

        assert_response :unprocessable_entity
        assert_match(/not saved/i, response.body)
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

      {
        "the signature check" => [ :validate, -> { RpmsRpc::Error.new(SYNTHETIC_BROKER_MESSAGE) } ],
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

      # -- The signature code stays out of the page, the log and the audit ------

      test "the signature code of a signed note is in no response, log line or audit row" do
        sign_in_provider!
        AuditEvent.delete_all

        logs = capture_request_logs { post_note }

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
        AuditEvent.delete_all

        logs = capture_request_logs { post_note }

        assert_response :unprocessable_entity
        refute_includes response.body, SYNTHETIC_SIGNATURE_CODE
        refute_includes logs, SYNTHETIC_SIGNATURE_CODE
        refute_includes AuditEvent.all.map { |event| event.attributes.to_s }.join, SYNTHETIC_SIGNATURE_CODE
      end
    end
  end
end
