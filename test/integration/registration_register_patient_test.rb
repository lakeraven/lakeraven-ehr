# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-02: the front desk registers a new patient. RPMS decides who may
# be filed (RpmsRpc::Patient.register's candidate lookup, then AG's add); these
# tests stand in for it at the gem boundary and check what the screens do with
# its answers, above all that the "different person" override cannot be forged.
class RegistrationRegisterPatientTest < ActionDispatch::IntegrationTest
  include RegistrationFormHelper

  ENTRY = { name: "PROBE,ALPHA", sex: "F", dob: "1990-05-01", ssn: "", tribe_ien: "611", community_ien: "16379" }.freeze
  HEADERS = {
    3 => { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", mrn: "1001" },
    990_057 => { name: "PROBE,ALPHA", dob: Date.new(1990, 5, 1), sex: "F", mrn: "990057" },
    77 => { name: "PROBE,OTHER", dob: Date.new(1990, 5, 1), sex: "M", mrn: "77" },
    88 => { name: nil, dob: nil, sex: nil, mrn: nil }
  }.freeze

  def sign_in(keys, duz: "207")
    post "/lakeraven-ehr/test_session", params: { duz: duz, user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  # Answers Patient.register from a script, one reply per call, and records each call.
  def with_register(*replies)
    calls = []
    patient = RpmsRpc::Patient.singleton_class
    patient.alias_method(:__register, :register)
    patient.alias_method(:__brief_header, :brief_header)
    RpmsRpc::Patient.define_singleton_method(:register) do |attrs|
      calls << attrs
      replies.shift
    end
    RpmsRpc::Patient.define_singleton_method(:brief_header) { |dfn| HEADERS[dfn.to_i] }
    yield calls
  ensure
    patient.alias_method(:register, :__register)
    patient.remove_method(:__register)
    patient.alias_method(:brief_header, :__brief_header)
    patient.remove_method(:__brief_header)
  end

  def possible(*dfns) = { success: false, error: :duplicate_identity, candidate_dfns: dfns, message: "matching patient candidates require explicit override" }

  def registered(dfn) = { success: true, dfn: dfn, created: true }

  def review_token
    css_select("#confirm-different-person input[name='review_token']").first["value"]
  end

  test "registering takes AGZMENU or AGZMGR: a view-only key is refused" do
    sign_in("registration_view_only")
    get "/lakeraven-ehr/registration/patients/new"

    assert_response :forbidden
  end

  test "S-REG-02.1 a new patient is registered and shows the health record number RPMS gave" do
    sign_in("registration_menu")
    with_register(registered(990_057)) do |calls|
      submit_registration(ENTRY)

      assert_equal 1, calls.size
      refute calls.first.key?(:allow_duplicate), "a first save never overrides"
      assert_redirected_to "/lakeraven-ehr/registration/patients/990057"
      follow_redirect!
      assert_select "#registered", text: /Health record number 990057/
    end
  end

  test "S-REG-02.2 a missing field is named and RPMS is not asked" do
    sign_in("registration_menu")
    with_register do |calls|
      submit_registration(ENTRY.merge(sex: ""))

      assert_response :unprocessable_content
      assert_select "#registration-errors li", text: /Sex/
      assert_empty calls
    end
  end

  test "S-REG-02.3 possible matches are shown with their chart numbers, and nothing is filed" do
    sign_in("registration_menu")
    with_register(possible(3)) do |calls|
      submit_registration(ENTRY)

      assert_response :conflict
      assert_select "#possible-matches tr[data-dfn='3'] td", text: "1001"
      assert_select "#possible-matches a[href='/lakeraven-ehr/registration/patients/3']"
      assert_equal 1, calls.size
    end
  end

  test "confirming a different person asks again, and files with the override only for the matches reviewed" do
    sign_in("registration_menu")
    with_register(possible(3), possible(3), registered(990_057)) do |calls|
      submit_registration(ENTRY)
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: review_token, registration: ENTRY }

      assert_redirected_to "/lakeraven-ehr/registration/patients/990057"
      assert_equal [ false, false, true ], calls.map { |attrs| attrs[:allow_duplicate] == true }
    end
  end

  test "a match that appears after the review is shown, not overridden" do
    sign_in("registration_menu")
    with_register(possible(3), possible(3, 77)) do |calls|
      submit_registration(ENTRY)
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: review_token, registration: ENTRY }

      assert_response :conflict
      assert_select "#possible-matches tr[data-dfn='77']"
      assert_equal 2, calls.size
      refute calls.any? { |attrs| attrs[:allow_duplicate] }
    end
  end

  test "a review cannot be replayed onto other details" do
    sign_in("registration_menu")
    with_register(possible(3)) do |calls|
      submit_registration(ENTRY)
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: review_token, registration: ENTRY.merge(dob: "1985-01-01") }

      assert_response :unprocessable_content
      assert_equal 1, calls.size
    end
  end

  test "a review cannot be used by another user, forged, or used after it expires" do
    sign_in("registration_menu")
    with_register(possible(3)) do |calls|
      submit_registration(ENTRY)
      token = review_token

      sign_in("registration_menu", duz: "208")
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: ENTRY }
      assert_response :unprocessable_content

      sign_in("registration_menu")
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: "#{token}x", registration: ENTRY }
      assert_response :unprocessable_content

      travel 16.minutes do
        post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: ENTRY }
        assert_response :unprocessable_content
      end

      assert_equal 1, calls.size, "no confirmation reached RPMS"
    end
  end

  # Review finding: a candidate RPMS will not describe could be signed as
  # "reviewed" without being shown. It is not shown, and there is no override.
  test "a possible match RPMS cannot describe leaves no override, only a search" do
    sign_in("registration_menu")
    with_register(possible(3, 88)) do |calls|
      submit_registration(ENTRY)

      assert_response :conflict
      assert_select "#possible-matches tr[data-dfn='3']"
      assert_select "#unshowable-match", text: /could not describe/
      assert_select "#confirm-different-person", count: 0
      assert_equal 1, calls.size
    end
  end

  # Review finding: two confirms of one review (a double click) must not file twice.
  test "a review files at most once: a second confirm of it is refused before RPMS is asked" do
    sign_in("registration_menu")
    with_register(possible(3), possible(3), registered(990_057)) do |calls|
      submit_registration(ENTRY)
      token = review_token
      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: ENTRY }
      assert_redirected_to "/lakeraven-ehr/registration/patients/990057"

      post "/lakeraven-ehr/registration/patients/confirm", params: { review_token: token, registration: ENTRY }

      assert_response :conflict
      assert_select "[role='alert']", text: /already used/
      assert_equal 3, calls.size, "the second confirm reached RPMS"
    end
  end

  # Review finding: a chart that was filed must not read as "not registered".
  test "a chart filed without its health record number opens, and says the number is missing" do
    sign_in("registration_menu")
    with_register({ success: false, error: :hrn_file_failed, dfn: 990_057, message: "" }) do
      submit_registration(ENTRY)

      assert_redirected_to "/lakeraven-ehr/registration/patients/990057"
      follow_redirect!
      assert_select "#registration-alert", text: /did not file a health record number/
    end
  end

  test "no answer from RPMS, or an error mid-save, is an unknown outcome with a search, not a retry" do
    sign_in("registration_menu")
    with_register(nil) do
      submit_registration(ENTRY)

      assert_response :service_unavailable
      assert_select "#outcome-unknown", text: /do not register them again yet/
      assert_select "#search-after-unknown[href*='q=PROBE%2CALPHA']"
      assert_select "#registration-form", count: 0
    end

    patient = RpmsRpc::Patient.singleton_class
    patient.alias_method(:__register, :register)
    RpmsRpc::Patient.define_singleton_method(:register) { |_attrs| raise RpmsRpc::Client::ConnectionError, "socket closed" }
    submit_registration(ENTRY)
    assert_response :service_unavailable
    assert_select "#outcome-unknown"
  ensure
    if patient&.method_defined?(:__register)
      patient.alias_method(:register, :__register)
      patient.remove_method(:__register)
    end
  end

  test "a registration RPMS refuses shows its reason" do
    sign_in("registration_menu")
    with_register({ success: false, error: :agg_rejected, message: "AG refused: NAME is required" }) do
      submit_registration(ENTRY)

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /AG refused: NAME is required/
    end
  end

  test "S-REG-01.2 no match offers to register a new patient" do
    sign_in("registration_menu")
    gateway = Lakeraven::EHR::PatientLookupGateway.singleton_class
    gateway.alias_method(:__find, :find)
    Lakeraven::EHR::PatientLookupGateway.define_singleton_method(:find) { |*, **| [] }

    get "/lakeraven-ehr/registration/patients", params: { q: "PROBE,ALPHA", dob: "1990-05-01" }

    assert_select "#register-new-patient[href*='registration%5Bname%5D=PROBE%2CALPHA']"
  ensure
    gateway.alias_method(:find, :__find)
    gateway.remove_method(:__find)
  end

  # #721: a double click, or a browser resending the form, posts the same form
  # twice. The second is refused before RPMS is asked, so one chart is filed.
  test "S-REG-02.1 a form submitted twice files one chart" do
    sign_in("registration_menu")
    with_register(registered(990_057), registered(990_058)) do |calls|
      token = registration_form_token
      post "/lakeraven-ehr/registration/patients", params: { submission_id: token, registration: ENTRY }
      assert_response :redirect

      post "/lakeraven-ehr/registration/patients", params: { submission_id: token, registration: ENTRY }
      assert_response :conflict
      assert_select "[role=alert]", text: /already submitted/
      assert_equal 1, calls.size, "RPMS was asked once"
    end
  end

  test "a registration that does not come from the form is refused before RPMS is asked" do
    sign_in("registration_menu")
    with_register(registered(990_057)) do |calls|
      post "/lakeraven-ehr/registration/patients", params: { registration: ENTRY }
      assert_response :unprocessable_content
      post "/lakeraven-ehr/registration/patients", params: { submission_id: "not-a-token", registration: ENTRY }
      assert_response :unprocessable_content
      assert_empty calls
    end
  end

  test "a form shown again after RPMS refused it can be submitted again" do
    sign_in("registration_menu")
    refused = { success: false, error: :agg_rejected, message: "Tribe is required" }
    with_register(refused, registered(990_057)) do |calls|
      first = registration_form_token
      post "/lakeraven-ehr/registration/patients", params: { submission_id: first, registration: ENTRY }
      assert_response :unprocessable_content
      again = css_select("#registration-form input[name='submission_id']").first["value"]
      refute_equal first, again, "the form shown again carries a new token"

      post "/lakeraven-ehr/registration/patients", params: { submission_id: again, registration: ENTRY }
      assert_response :redirect
      assert_equal 2, calls.size
    end
  end
end
