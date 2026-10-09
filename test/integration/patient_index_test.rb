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

  test "the index lists patients and links each to its chart via canonical path across variants" do
    sign_in_staff

    paths = [ "/lakeraven-ehr/patients", "/lakeraven-ehr/patients/", "/lakeraven-ehr/patients.html", "/lakeraven-ehr/patients.HTML" ]
    paths.each do |p|
      get p

      assert_response :success
      assert_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}"}, response.body,
        "every listed patient must link to its own chart canonically, no format segment")

      assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}\.html"}, response.body,
        "must not carry .html extension in chart link")
      assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/#{known_dfn}\.HTML"}, response.body,
        "must not carry .HTML extension in chart link")

      assert_select "h1", /Patients/i
    end
  end

  test "the index shows enough to tell two patients apart" do
    sign_in_staff

    get "/lakeraven-ehr/patients"

    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/, response.body,
      "a list of identifiers nobody recognises is not a way in")
    assert_match(/#{known_dfn}/, response.body, "the identifier a clinician would quote")

    assert_no_match(/DOB|Date of Birth/i, response.body, "DOB column must not be present because RPMS does not return it here")
    assert_no_match(/Sex|Gender/i, response.body, "Sex column must not be present because RPMS does not return it here")
  end

  # --- 2. Name search ------------------------------------------------------

  test "a name search acts as a cursor" do
    sign_in_staff

    seen = []
    client = RpmsRpc.configuration.client
    orig = client.method(:call_rpc)
    client.define_singleton_method(:call_rpc) { |*a| seen << a if a[0] == "ORWPT LIST ALL"; orig.call(*a) }

    # When name is a typed string, it stays name-only
    get "/lakeraven-ehr/patients", params: { name: "Anderson" }

    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/1"}, response.body)
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/2"}, response.body,
      "a non-matching patient is absent")

    assert_match(/Starting at Anderson/i, response.body, "the page must label the name parameter as a cursor")

    assert_equal 1, seen.size
    assert_equal "Anderson", seen.first[1], "typed name stays name-only in the RPC request"

    # When name is the raw ^ form from Next
    seen.clear
    get "/lakeraven-ehr/patients", params: { name: "1^Anderson,Alice" }

    assert_response :success
    assert_match(/Starting at Anderson,Alice/i, response.body, "the page must label the name parameter as a cursor, showing only the name part")
    assert_no_match(/1\^Anderson,Alice/, response.body, "must never show the raw ^ form")

    assert_equal 1, seen.size
    assert_equal "1^Anderson,Alice", seen.first[1], "exact IEN^Name string reaches the RPC as FROM"

    # Positive control: Mickey Mouse (DFN 2) appears without the filter
    get "/lakeraven-ehr/patients"
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/2"}, response.body,
      "positive control: patient is visible without the filter")
  end

  test "a full page of 44 patients offers a next link based on RPC results, not filtered results, and the cursor is IEN^Name" do
    sign_in_staff

    list_44 = 44.times.map do |i|
      { dfn: 100 + i, name: "P#{i.to_s.rjust(2, '0')},Test", sex: "M", dob: Date.parse("1970-01-01") }
    end

    RpmsRpc.mock! do |m|
      list_44.each do |r|
        site = r[:dfn] == 100 ? 9999 : 7819
        m.seed(:patient_select, r[:dfn].to_s, { name: r[:name], sex: "M", dob: Date.parse("1970-01-01"), ssn: "000-00-#{r[:dfn]}", age: 50 })
        m.seed(:patient_id_info, r[:dfn].to_s, { ssn: "000-00-#{r[:dfn]}", dob: Date.parse("1970-01-01"), sex: "M", race_code: "I", site_ien: site, name: r[:name] })
      end
      m.seed_collection(:patient_list, list_44, filter_field: :name)
    end

    get "/lakeraven-ehr/patients"
    assert_response :success

    assert_match(/Next/i, response.body, "44 rows must offer a next link for unbound staff")
    assert_equal 44, response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/1\d\d"}).size, "positive control: unbound credential sees 44 rows"

    # The cursor must be IEN^Name, correctly URL-escaped
    last_dfn = "143"
    last_name = "P43,Test"
    cursor = "#{last_dfn}^#{last_name}"
    escaped_cursor = CGI.escape(cursor)
    assert_match(/name=#{escaped_cursor}/i, response.body, "the next link cursor must be the last row's IEN^Name")

    # The label must only show the name part
    assert_no_match(/Starting at #{Regexp.escape(cursor)}/i, response.body, "the label must not show the raw ^ form")

    app = Doorkeeper::Application.find_by!(uid: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID)
    app.update!(organization_id: "rpms-organization-7819")

    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/Next/i, response.body, "44 RPC rows where one is filtered out must still offer a Next link")
    assert_equal 43, response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/1\d\d"}).size, "org-bound credential sees 43 rows"

    list_43 = 43.times.map do |i|
      { dfn: 200 + i, name: "Short#{i},Test", sex: "M", dob: Date.parse("1970-01-01") }
    end

    RpmsRpc.mock! do |m|
      m.seed_collection(:patient_list, list_43, filter_field: :name)
    end

    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_no_match(/Next/i, response.body, "fewer than 44 rows means no next link is offered")
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

  test "staff credentials are not org-bound and can see all patients" do
    sign_in_staff

    sso_app = Doorkeeper::Application.find_by(uid: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID)
    assert_nil sso_app.organization_id, "the browser SSO app must not be org-bound"

    get "/lakeraven-ehr/patients"

    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/#{FOREIGN_DFN}"}, response.body,
      "staff can see foreign site patients because they are not org-bound")
  end

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

  test "org comparison fails closed on malformed sites" do
    sign_in_staff

    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(%r{href="[^"]*/lakeraven-ehr/patients/888"}, response.body, "positive control: unbound staff sees the blank-site patient")

    app = Doorkeeper::Application.find_by!(uid: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID)
    app.update!(organization_id: "rpms-organization-0")

    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_no_match(%r{href="[^"]*/lakeraven-ehr/patients/888"}, response.body, "org-bound staff bound to 0 sees no patient whose site is 0/blank")
  end

  # --- 5. Patient login refused --------------------------------------------

  test "a token with a patient/ scope gets 403 and sees no patient rows" do
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

    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
  end

  # --- 6. Machine credential refused ---------------------------------------

  test "a bearer system/Patient.read token gets 403 and sees no patient rows" do
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

    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body)
  end

  test "explicit non-HTML formats are refused after authentication and leave exactly one failure audit row" do
    # Unauthenticated gets 401
    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients.json"
    assert_response :unauthorized

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "401 must leave exactly one audit row"
    assert_not_equal "0", events.first.outcome
    assert_nil events.first.entity_identifier

    # Patient credential gets 403
    app = Doorkeeper::Application.create!(
      name: "patient-app-2", redirect_uri: "https://example.test/callback",
      scopes: "patient/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "patient/*.read", expires_in: 3600,
      resource_owner_id: known_dfn
    )
    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients.xml", headers: bearer(token)
    assert_response :forbidden
    assert_no_match(/Anderson/i, response.body, "must not disclose names")
    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "403 must leave exactly one audit row for patient credential"
    assert_not_equal "0", events.first.outcome
    assert_nil events.first.entity_identifier

    # System credential gets 403
    sys_app = Doorkeeper::Application.create!(
      name: "machine-app-2", redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read", confidential: true
    )
    sys_token = Doorkeeper::AccessToken.create!(
      application: sys_app, scopes: "system/Patient.read", expires_in: 3600
    )
    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients.json", headers: bearer(sys_token)
    assert_response :forbidden
    assert_no_match(/Anderson/i, response.body, "must not disclose names")
    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "403 must leave exactly one audit row for system credential"
    assert_not_equal "0", events.first.outcome
    assert_nil events.first.entity_identifier

    # Staff credential gets 406
    sign_in_staff
    [ "json", "xml", "JSON" ].each do |ext|
      Lakeraven::EHR::AuditEvent.delete_all
      get "/lakeraven-ehr/patients.#{ext}"
      assert_response :not_acceptable, ".#{ext} extension must be 406 for staff"
      assert_no_match(/Anderson/i, response.body, "must not disclose names")

      events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
      assert_equal 1, events.size, "406 must leave exactly one audit row"
      assert_not_equal "0", events.first.outcome
      assert_nil events.first.entity_identifier
    end

    [ "json", "xml", "JSON" ].each do |f|
      Lakeraven::EHR::AuditEvent.delete_all
      get "/lakeraven-ehr/patients", params: { format: f }
      assert_response :not_acceptable, "?format=#{f} must be 406 for staff"
      assert_no_match(/Anderson/i, response.body, "must not disclose names")

      events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
      assert_equal 1, events.size, "406 must leave exactly one audit row"
      assert_not_equal "0", events.first.outcome
      assert_nil events.first.entity_identifier
    end
  end

  test "Accept header never selects a format, they get the HTML list" do
    sign_in_staff

    get "/lakeraven-ehr/patients", headers: { "Accept" => "application/json" }
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body, "must return HTML list")

    get "/lakeraven-ehr/patients", headers: { "Accept" => "application/fhir+json" }
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body, "must return HTML list")

    get "/lakeraven-ehr/patients", params: { _format: "json" }
    assert_response :success
    assert_match(/#{Regexp.escape(known_patient.display_name)}/i, response.body, "must return HTML list")
  end

  # --- 7. Audit names who was shown ----------------------------------------

  test "a list request audits exactly the set of patients rendered in the page, each exactly once, and an empty page writes exactly one row without a patient" do
    sign_in_staff

    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients"
    assert_response :success

    rendered_dfns = response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/(\d+)"}).flatten
    audited_dfns = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient", outcome: "0").pluck(:entity_identifier)

    assert_equal rendered_dfns.sort, audited_dfns.sort, "audited DFNs must match exactly the rendered DFNs"
    assert_equal audited_dfns.uniq.size, audited_dfns.size, "each DFN must be audited exactly once"
    assert_not_includes audited_dfns, nil, "non-empty page must not have an extra request-level row"

    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients", params: { name: "Anderson" }
    assert_response :success

    rendered_dfns = response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/(\d+)"}).flatten
    audited_dfns = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient", outcome: "0").pluck(:entity_identifier)

    assert_equal rendered_dfns.sort, audited_dfns.sort, "audited DFNs must match exactly the rendered DFNs on search"
    assert_equal audited_dfns.uniq.size, audited_dfns.size, "each DFN must be audited exactly once on search"
    assert_not_includes audited_dfns, nil, "non-empty page must not have an extra request-level row"

    Lakeraven::EHR::AuditEvent.delete_all
    site = Lakeraven::EHR::Patient.find_by_dfn(known_dfn).site_ien
    app = Doorkeeper::Application.find_by!(uid: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID)
    app.update!(organization_id: "rpms-organization-#{site}")

    get "/lakeraven-ehr/patients"
    assert_response :success

    rendered_dfns = response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/(\d+)"}).flatten
    audited_dfns = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient", outcome: "0").pluck(:entity_identifier)

    assert_equal rendered_dfns.sort, audited_dfns.sort, "audited DFNs must match exactly the rendered DFNs on org-bound list"
    assert_equal audited_dfns.uniq.size, audited_dfns.size, "each DFN must be audited exactly once on org-bound list"
    assert_not_includes audited_dfns, FOREIGN_DFN, "foreign patient hid by org filter must not have a success audit row"
    assert_not_includes audited_dfns, nil, "non-empty page must not have an extra request-level row"

    # Empty page because name matches nothing
    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients", params: { name: "ZZZZZZZZZ" }
    assert_response :success

    assert_empty response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/(\d+)"}).flatten
    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "empty page must leave exactly one audit row"
    assert_equal "0", events.first.outcome, "the empty page audit row must be a success outcome"
    assert_nil events.first.entity_identifier, "the empty page audit row must not carry a patient DFN"

    # Empty page because org filter blocks all
    app.update!(organization_id: "rpms-organization-999999")
    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients"
    assert_response :success

    assert_empty response.body.scan(%r{href="[^"]*/lakeraven-ehr/patients/(\d+)"}).flatten
    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "empty page must leave exactly one audit row"
    assert_equal "0", events.first.outcome, "the empty page audit row must be a success outcome"
    assert_nil events.first.entity_identifier, "the empty page audit row must not carry a patient DFN"
  end

  test "a 401/403/error request leaves exactly one denial audit row without a DFN" do
    Lakeraven::EHR::AuditEvent.delete_all
    get "/lakeraven-ehr/patients"
    assert_response :unauthorized

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "401 must leave exactly one audit row"
    assert_not_equal "0", events.first.outcome, "the 401 audit row must be a failure outcome"
    assert_nil events.first.entity_identifier, "the 401 audit row must not carry a patient DFN"

    Lakeraven::EHR::AuditEvent.delete_all
    sign_in_staff(username: "testclerk")
    get "/lakeraven-ehr/patients"
    assert_response :forbidden

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "403 must leave exactly one audit row"
    assert_not_equal "0", events.first.outcome, "the 403 audit row must be a failure outcome"
    assert_nil events.first.entity_identifier, "the 403 audit row must not carry a patient DFN"

    Lakeraven::EHR::AuditEvent.delete_all
    sign_in_staff(username: "lindarodriguez")

    RpmsRpc.configure { |c| c.client = FakeBroker.new.raise_with(RuntimeError.new("database offline")) }

    error = assert_raises(RuntimeError) do
      get "/lakeraven-ehr/patients"
    end
    assert_equal "database offline", error.message

    events = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient")
    assert_equal 1, events.size, "a raising search must leave exactly one audit row"
    assert_not_equal "0", events.first.outcome, "the raised search audit row must be a failure outcome"
    assert_nil events.first.entity_identifier, "the raised search audit row must not carry a patient DFN"
  end

  # --- 8. Dev bypass unchanged ---------------------------------------------

  test "the dev bypass does not open the index route in the test environment" do
    ENV["CHART_DEMO_OPEN"] = "1"
    ENV["SPIKE_MOCK_RPC"] = "1"

    get "/lakeraven-ehr/patients"

    assert_response :unauthorized, "dev bypass must not apply outside development"
  ensure
    ENV.delete("CHART_DEMO_OPEN")
    ENV.delete("SPIKE_MOCK_RPC")
  end

  test "the list page does not hardcode a synthetic demo badge" do
    sign_in_staff
    get "/lakeraven-ehr/patients"
    assert_response :success
    assert_no_match(/Synthetic demo data/i, response.body, "the view must not hard-code the synthetic badge on real deployments")
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

    # Malformed site for "org comparison fails closed on malformed sites" test
    m.seed(:patient_select, "888", { name: "BlankSite,Patient", sex: "M", dob: Date.parse("1970-01-01"), ssn: "000-00-0000", age: 50 })
    m.seed(:patient_id_info, "888", { ssn: "000-00-0000", dob: Date.parse("1970-01-01"), sex: "M", race_code: "I", site_ien: 0, name: "BlankSite,Patient" })

    # Append the foreign patient to the patient_list
    existing_list = [
      { dfn: 1, name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15") },
      { dfn: 2, name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14") },
      { dfn: 3, name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25") },
      { dfn: FOREIGN_DFN.to_i, name: "Farwood,Dale", sex: "M", dob: Date.parse("1966-02-09") },
      { dfn: 888, name: "BlankSite,Patient", sex: "M", dob: Date.parse("1970-01-01") }
    ]
    m.seed_collection(:patient_list, existing_list, filter_field: :name)
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
