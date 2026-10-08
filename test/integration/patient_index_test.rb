# frozen_string_literal: true

require "test_helper"

# The clinician-facing way in to a patient's chart.
#
# AUDIT REPRESENTATION CHOICE (Behaviour 7):
# AuditableClinicalAccess typically records one event per request. However,
# since this is a list of patients, one event with a blank entity is not
# sufficient to name who was shown. I have chosen the representation:
# "one audit event per listed patient", where `entity_identifier` is the DFN.
# The builder should bypass or augment the standard single-event wrap to
# persist an audit row per patient rendered.
class PatientIndexTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    @original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! do |m|
      m.seed_user("303", credentials: "testclerk;test123", name: "CLERK,TEST", role: :clerk)
      m.seed_user("304", credentials: "lindarodriguez;test123", name: "RODRIGUEZ,LINDA", role: :case_manager,
                         security_keys: [ :prc_supervisor, :cprs_gui_chart ])

      m.seed(:patient_select, "1", { name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15"), ssn: "111-11-1111", age: 45 })
      m.seed(:patient_select, "2", { name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14"), ssn: "000009999", age: 16 })
      m.seed(:patient_select, "3", { name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25"), ssn: "555667777", age: 35 })

      m.seed(:patient_id_info, "1", { ssn: "111-11-1111", dob: Date.parse("1980-05-15"), sex: "F", race_code: "I", site_ien: 7819, name: "Anderson,Alice" })
      m.seed(:patient_id_info, "2", { ssn: "000009999", dob: Date.parse("2010-02-14"), sex: "M", race_code: "I", site_ien: 7819, name: "MOUSE,MICKEY M" })
      m.seed(:patient_id_info, "3", { ssn: "555667777", dob: Date.parse("1990-12-25"), sex: "F", race_code: "I", site_ien: 7819, name: "DOE,JANE" })

      seed_patient_at_another_site(m)
    end
    # Clear any previous audit events
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown do
    teardown_smart_auth
    RpmsRpc.configure { |c| c.client = @original_client }
    Lakeraven::EHR::LoginThrottle.reset!
  end

  # --- 1. List and link ----------------------------------------------------

  test "the index lists patients and links each to its chart" do
    sign_in_staff

    get "/lakeraven-ehr/patients"

    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body,
      "every listed patient must link to its own chart")
    assert_select "h1", /Patients/i
  end

  test "the index shows enough to tell two patients apart" do
    sign_in_staff

    get "/lakeraven-ehr/patients"

    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/, response.body,
      "a list of identifiers nobody recognises is not a way in")
    assert_match(/#{known_dfn}/, response.body, "the identifier a clinician would quote")
  end

  # --- 2. Name search ------------------------------------------------------

  test "a name search narrows the list" do
    sign_in_staff

    # Search by Alice's surname
    get "/lakeraven-ehr/patients", params: { name: "Anderson" }

    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/1"}, response.body)
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/2"}, response.body,
      "a non-matching patient is absent")

    # Positive control: Mickey Mouse (DFN 2) appears without the filter
    get "/lakeraven-ehr/patients"
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/2"}, response.body,
      "positive control: patient is visible without the filter")
  end

  # --- 3. Authentication and scope -----------------------------------------

  test "an unauthenticated visitor gets 401" do
    get "/lakeraven-ehr/patients"

    assert_response :unauthorized, "no credential -> 401"
  end

  test "a staff credential without Patient read scope is refused (403)" do
    # 'testclerk' has no security keys and gets no clinical scopes
    sign_in_staff(username: "testclerk")

    get "/lakeraven-ehr/patients"

    assert_response :forbidden, "staff credential without Patient read scope -> 403"
  end

  # --- 4. Organization scoping ---------------------------------------------

  # Staff credentials (browser session tokens) on this tree are NEVER org-bound.
  # The SSO application is a singleton (BROWSER_SSO_APP_UID) with no organization_id.
  # Therefore, a test asserting they cannot see another organization's patients
  # cannot fail and is not written.
  # Instead, we prove that the staff application indeed has no organization,
  # and that a staff user CAN see the foreign patient (positive control for the
  # absence of org-binding).
  test "staff credentials are not org-bound and can see all patients" do
    sign_in_staff

    sso_app = Doorkeeper::Application.find_by(uid: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID)
    assert_nil sso_app.organization_id, "the browser SSO app must not be org-bound"

    get "/lakeraven-ehr/patients"

    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/#{FOREIGN_DFN}"}, response.body,
      "staff can see foreign site patients because they are not org-bound")
  end

  # The browser SSO application is unbound, so the test above cannot pin the
  # filter. Bind that same staff credential to the home site and the foreign
  # patient must disappear; the home patient must stay.
  test "an org-bound staff credential lists only that organization's patients" do
    sign_in_staff

    site = Lakeraven::EHR::Patient.find_by_dfn(known_dfn).site_ien
    app = Doorkeeper::Application.find_by!(uid: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID)
    app.update!(organization_id: "rpms-organization-#{site}")

    get "/lakeraven-ehr/patients"

    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body,
      "a patient at the credential's organization stays listed")
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{FOREIGN_DFN}"}, response.body,
      "a patient outside the credential's organization must not be listed")
  end

  # --- 5. Patient login refused --------------------------------------------

  test "a token with a patient/ scope gets 403 and sees no patient rows" do
    # Mint a token with patient/ scope (e.g. a patient login)
    app = Doorkeeper::Application.create!(
      name: "patient-app", redirect_uri: "https://example.test/callback",
      scopes: "patient/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "patient/*.read", expires_in: 3600,
      resource_owner_id: known_dfn
    )

    get "/lakeraven-ehr/patients", headers: bearer(token)

    assert_response :forbidden
    assert_no_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body)

    # Positive control: a staff credential sees rows
    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
  end

  test "a token with a patient/ scope mixed with a broader scope gets 403 and sees no patient rows" do
    app = Doorkeeper::Application.create!(
      name: "mixed-scope-app", redirect_uri: "https://example.test/callback",
      scopes: "patient/*.read user/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "patient/*.read user/*.read", expires_in: 3600,
      resource_owner_id: known_dfn
    )

    get "/lakeraven-ehr/patients", headers: bearer(token)

    assert_response :forbidden
    assert_no_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body)

    # Positive control: a staff credential sees rows
    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
  end

  # --- 6. Machine credential refused ---------------------------------------

  test "a bearer system/Patient.read token gets 403 and sees no patient rows" do
    # Mint an unbound system/ scope token
    app = Doorkeeper::Application.create!(
      name: "machine-app", redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read", expires_in: 3600
    )

    get "/lakeraven-ehr/patients", headers: bearer(token)

    assert_response :forbidden
    assert_no_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body)

    # Positive control: a staff credential sees rows
    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
  end

  test "a system/Patient.read token for an org-bound application gets 403 and sees no patient rows" do
    app = Doorkeeper::Application.create!(
      name: "org-bound-machine-app", redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read", confidential: true,
      organization_id: "example-organization-1"
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read", expires_in: 3600
    )

    get "/lakeraven-ehr/patients", headers: bearer(token)

    assert_response :forbidden
    assert_no_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body)

    # Positive control: a staff credential sees rows
    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
  end

  # --- 7. Audit names who was shown ----------------------------------------

  test "a list request leaves an audit row per listed patient DFN" do
    sign_in_staff

    get "/lakeraven-ehr/patients"
    assert_response :success

    # We expect one audit event for DFN 1, one for DFN 2, one for DFN 3, etc.
    rendered_dfns = [ 1, 2, 3, FOREIGN_DFN.to_i ]

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")

    rendered_dfns.each do |dfn|
      assert events.exists?(entity_identifier: dfn.to_s),
        "missing audit row for rendered patient DFN #{dfn}"
    end
  end

  test "a 401/403 request must not record any listed DFN" do
    # Test 401
    get "/lakeraven-ehr/patients"
    assert_response :unauthorized

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_empty events, "401 request must not record any patient DFNs"

    # Test 403 (clerk with no scope)
    Lakeraven::EHR::AuditEvent.delete_all
    sign_in_staff(username: "testclerk")
    get "/lakeraven-ehr/patients"
    assert_response :forbidden

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_empty events, "403 request must not record any patient DFNs"
  end

  # --- 8. Dev bypass unchanged ---------------------------------------------

  test "the dev bypass does not open the index route in the test environment" do
    # Ensure bypass conditions are met in ENV, though Rails.env is test
    ENV["CHART_DEMO_OPEN"] = "1"
    ENV["SPIKE_MOCK_RPC"] = "1"

    get "/lakeraven-ehr/patients"

    assert_response :unauthorized, "dev bypass must not apply outside development"
  ensure
    ENV.delete("CHART_DEMO_OPEN")
    ENV.delete("SPIKE_MOCK_RPC")
  end

  private

  def sign_in_staff(username: "lindarodriguez", password: "test123")
    post "/lakeraven-ehr/login", params: { username: username, password: password }
    assert session[:duz].present?, "the canned test sign-in did not establish a session"
  end

  def known_patient
    @known_patient ||= Lakeraven::EHR::Patient.search("").first
  end

  def known_dfn
    "1"
  end

  FOREIGN_DFN = "9007"
  FOREIGN_SITE = 9999

  def seed_patient_at_another_site(m)
    m.seed(:patient_select, FOREIGN_DFN, { name: "Farwood,Dale", sex: "M",
                                          dob: Date.parse("1966-02-09"), ssn: "900-00-9007", age: 60 })
    m.seed(:patient_id_info, FOREIGN_DFN, {
      ssn: "900-00-9007", dob: Date.parse("1966-02-09"), sex: "M",
      race_code: "I", site_ien: FOREIGN_SITE, name: "Farwood,Dale"
    })

    # Append the foreign patient to the patient_list
    existing_list = [
      { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15") },
      { dfn: 2, name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14") },
      { dfn: 3, name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25") },
      { dfn: FOREIGN_DFN.to_i, name: "Farwood,Dale", sex: "M", dob: Date.parse("1966-02-09") }
    ]
    m.seed_collection(:patient_list, existing_list, filter_field: :name)
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
