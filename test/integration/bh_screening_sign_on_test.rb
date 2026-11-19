# frozen_string_literal: true

require "test_helper"

# Issue #526 acceptance: BH keys mint QuestionnaireResponse scopes through the
# real sign-on bridge; chart-only users cannot open or save screenings.
class BhScreeningSignOnTest < ActionDispatch::IntegrationTest
  LOGIN = "/lakeraven-ehr/login"
  MOUNT = "/lakeraven-ehr"
  BASE = "#{MOUNT}/patients/1/screenings"
  VISIT = "2090061"
  PHQ9 = Lakeraven::EHR::ScreeningInstrument::PHQ9
  BROWSER_UID = Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID
  QR_SCOPE = "user/QuestionnaireResponse.cruds"

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    seed_bh_users
    seed_open_visit
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was unless @forgery_was.nil?
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::ScreeningResponse.delete_all
  end

  test "a behavioral_health_user through real login posts PHQ-9 item 9 positive and gets the safety prompt" do
    sign_in_through_bridge("bhtestuser", "test123")
    assert_token_includes_qr_scope

    open_patient_context!

    post BASE, params: phq9_item9_positive_params

    assert_response :unprocessable_entity
    assert_equal 0, Lakeraven::EHR::ScreeningResponse.count
    assert_select ".screening-safety[role=alert]"
    assert_select ".screening-safety h2", /Safety check required/
  end

  test "a behavioral_health_manager through real login posts PHQ-9 item 9 positive and gets the safety prompt" do
    sign_in_through_bridge("bhmgr", "test123")
    assert_token_includes_qr_scope

    open_patient_context!

    post BASE, params: phq9_item9_positive_params

    assert_response :unprocessable_entity
    assert_equal 0, Lakeraven::EHR::ScreeningResponse.count
    assert_select ".screening-safety[role=alert]"
  end

  test "a chart-only user through real login is forbidden to open and to save a screening" do
    sign_in_through_bridge("testprovider", "test123")
    refute_includes session_token.scopes.to_a, QR_SCOPE

    open_patient_context!

    get "#{BASE}/new", params: { instrument: "phq-9", encounter_ien: VISIT }
    assert_response :forbidden

    post BASE, params: phq9_item9_positive_params
    assert_response :forbidden
    assert_equal 0, Lakeraven::EHR::ScreeningResponse.count
  end

  test "the browser SSO Doorkeeper application declares QuestionnaireResponse in its scope set" do
    sign_in_through_bridge("bhtestuser", "test123")

    app = Doorkeeper::Application.find_by!(uid: BROWSER_UID)
    declared = app.scopes.to_s.split
    assert_includes declared, QR_SCOPE
    assert_includes Lakeraven::EHR::SessionScopePolicy.all_scopes, QR_SCOPE
  end

  private

  def rpms_mock = RpmsRpc.client

  def seed_bh_users
    rpms_mock.seed_user("305", credentials: "bhtestuser;test123", name: "BH,TESTUSER", role: :provider)
    rpms_mock.seed_held_keys("305", [ "AMHZMENU" ])
    rpms_mock.seed_options("305", [ "CIAV VUECENTRIC" ])

    rpms_mock.seed_user("306", credentials: "bhmgr;test123", name: "BH,MANAGER", role: :provider)
    rpms_mock.seed_held_keys("306", [ "AMHZMGR" ])
    rpms_mock.seed_options("306", [ "CIAV VUECENTRIC" ])
  end

  # A screening is saved only against one of the patient's open visits
  # (#1003), read with the Encounter scope CIAV VUECENTRIC grants at sign-on.
  # Synthetic clinic and provider; checked in today.
  def seed_open_visit
    day = Date.current
    at = Time.zone.local(day.year, day.month, day.day, 9, 30)
    fileman = "#{at.year - 1700}#{at.strftime('%m%d')}.#{at.strftime('%H%M')}"
    rpms_mock.seed_keyed_collection(:encounter_visit_list, "1", [
      { visit_string: "40;#{fileman};A;#{VISIT}", location: "Riverbend Behavioral Health",
        category: "AMBULATORY", datetime: at, locked: false,
        provider_ien: 9001, provider: "TESTPROVIDER,ALPHA" }
    ])
  end

  def sign_in_through_bridge(username, password)
    post LOGIN, params: {
      username: username,
      password: password,
      authenticity_token: fetch_csrf_token
    }
    assert_response :redirect
  end

  def session_token
    Doorkeeper::AccessToken.order(:id).last
  end

  def assert_token_includes_qr_scope
    assert_includes session_token.scopes.to_a, QR_SCOPE
  end

  def csrf_param
    { authenticity_token: fetch_csrf_token }
  end

  # With forgery protection on, every POST needs the token from a page this
  # session may load. Sign-on resets the session, so callers after login must
  # fetch fresh (not reuse the pre-login token). GET /login still answers when
  # signed in; if routing ever sends a signed-in user elsewhere, follow it.
  def fetch_csrf_token
    get LOGIN
    follow_redirect! while response.redirect?
    token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
    assert token.present?, "expected CSRF meta tag (HTTP #{response.status})"
    token
  end

  def open_patient_context!
    post "#{MOUNT}/patients/1/context", params: csrf_param
    assert_response :redirect
  end

  def phq9_item9_positive_params
    answers = PHQ9.link_ids.index_with { 0 }
    answers[PHQ9.safety_link_id] = 2
    {
      instrument: PHQ9.key,
      encounter_ien: VISIT,
      answers: answers
    }.merge(csrf_param)
  end
end
