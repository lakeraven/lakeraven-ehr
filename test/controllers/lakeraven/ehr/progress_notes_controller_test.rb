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

      def get_new(tiu = @tiu)
        with_fake_tiu(tiu) { get NEW }
      end

      # Review round 3: an empty visit list is also what an empty broker reply
      # reads as, so the page does not tell the user flatly to check the
      # patient in.
      def assert_no_open_visit_page!
        assert_match(/no open visit was found/i, response.body)
        assert_match(/if the patient has been checked in, RPMS may not have answered/i, response.body)
        assert_match(/try again/i, response.body)
        assert_match(/check the chart/i, response.body)
        refute_match(/check the patient in first/i, response.body)
        refute_match(/has no open visit/i, response.body, "RPMS did not say so: none was found")
        assert_select "textarea[name=?]", "note_text", count: 0
        assert_select "input[name=?]", "signature_code", count: 0
        assert_select "input[name=?]", "visit_ien", count: 0
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

      test "GET new without the PROVIDER key is forbidden and reads nothing" do
        sign_in_with_keys!(NON_PROVIDER_KEYS)
        open_patient_context!(DFN)

        get_new

        assert_response :forbidden
        assert_empty @tiu.calls
        assert_select "textarea[name=?]", "note_text", count: 0
      end

      test "GET new for a patient whose record is not open in the session is forbidden" do
        sign_in_provider!(open: OTHER_DFN)

        get_new

        assert_response :forbidden
        assert_select "form[action=?]", "#{CHART}/context"
        assert_select "textarea[name=?]", "note_text", count: 0
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
        assert_no_open_visit_page!
      end

      test "GET new with no visits at all says there is no open visit" do
        sign_in_provider!
        tiu = FakeTiu.new(visits_by_dfn: {})

        get_new(tiu)

        assert_response :ok
        assert_match(/no open visit/i, response.body)
        assert_no_open_visit_page!
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

      # -- 6. One submission per form -------------------------------------------

      test "GET new carries a one-time form token in a hidden field of the note form" do
        sign_in_provider!

        get_new

        assert_response :ok
        assert_select "form[action=?] input[type=hidden][name=?]", BASE, FORM_TOKEN_FIELD, count: 1
        assert note_form_token_in_page.present?, "the token has a value"
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
        assert_no_open_visit_page!
      end
    end
  end
end
