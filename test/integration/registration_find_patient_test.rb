# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-01: the front desk finds the patient before registering.
class RegistrationFindPatientTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper
  # Looked up when a test runs, not when the file loads.
  def match(**attrs) = Lakeraven::EHR::PatientLookupGateway::Match.new(**attrs)

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  # Minitest 6 dropped Object#stub; swap a singleton method and put it back.
  def with_lookup(result = nil, raises: nil)
    gateway = Lakeraven::EHR::PatientLookupGateway
    asked = []
    gateway.singleton_class.alias_method(:__find, :find)
    gateway.define_singleton_method(:find) do |text, dob: nil, **|
      asked << [ text, dob ]
      raise raises if raises

      result
    end
    yield asked
  ensure
    gateway.singleton_class.alias_method(:find, :__find)
    gateway.singleton_class.remove_method(:__find)
  end

  # AG is IHS-only (#647): a backend without bprm_registration has no
  # registration screens, and nothing is asked of it.
  test "registration is not offered on a backend without bprm_registration" do
    sign_in("registration_menu")
    with_restricted_backend do
      before = RpmsRpc.client.received_calls.length
      get "/lakeraven-ehr/registration/patients"

      assert_response :not_found
      assert_no_rpc_calls_since(before)
    end
  end

  test "a user without a registration or scheduling key is refused" do
    sign_in("orders_sign")
    get "/lakeraven-ehr/registration/patients"

    assert_response :forbidden
  end

  # AG's lookup is refused to a scheduler by RPMS, so the search is not offered.
  test "a scheduler cannot search here, and can open a registration" do
    sign_in("scheduling_user")
    post "/lakeraven-ehr/registration/patients/search", params: { q: "MOUSE" }

    assert_response :forbidden
  end

  test "S-REG-01.1 a registered patient is listed with their health record number, and opens" do
    mouse = match(dfn: 3, name: "MOUSE,MICKEY M", hrn: "1001", dob: Date.new(1910, 2, 14), dod: nil, inactive: false)
    sign_in("registration_menu")

    with_lookup([ mouse ]) do |asked|
      post "/lakeraven-ehr/registration/patients/search", params: { q: "MOUSE", dob: "1910-02-14" }

      assert_equal [ [ "MOUSE", Date.new(1910, 2, 14) ] ], asked
    end

    assert_response :ok
    assert_select "#matches tr[data-dfn='3'] td", text: "1001"
    assert_select "#matches a[href='/lakeraven-ehr/registration/patients/3']", text: "MOUSE,MICKEY M"
  end

  test "S-REG-01.3 and 01.4 an inactive chart and a deceased patient are marked" do
    inactive = match(dfn: 5, name: "DUCK,DONALD", hrn: "1002", dob: Date.new(1934, 6, 9), dod: nil, inactive: true)
    deceased = match(dfn: 6, name: "DUCK,DAISY", hrn: "1003", dob: Date.new(1940, 1, 1), dod: Date.new(2020, 3, 1), inactive: false)
    sign_in("registration_view_only")

    with_lookup([ inactive, deceased ]) { post "/lakeraven-ehr/registration/patients/search", params: { q: "DUCK" } }

    assert_select "tr[data-dfn='5'] td[data-status='inactive']", text: "Inactive"
    assert_select "tr[data-dfn='6'] td[data-status='deceased']", text: /Deceased Mar 1, 2020/
  end

  test "S-REG-01.2 no match says so" do
    sign_in("registration_menu")
    with_lookup([]) { post "/lakeraven-ehr/registration/patients/search", params: { q: "ZZZNOBODY" } }

    assert_select "#no-match", text: /No patient matches “ZZZNOBODY”/
  end

  test "a lookup that fails says the results are not complete, never no match" do
    sign_in("registration_menu")
    with_lookup(raises: RpmsRpc::Client::RpcError.new("4 Access denied")) do
      post "/lakeraven-ehr/registration/patients/search", params: { q: "MOUSE" }
    end

    assert_response :service_unavailable
    assert_select "[role='alert']", text: /Do not register a new patient until a search succeeds/
    assert_select "#no-match", count: 0
  end

  test "the registration shows the health record number, date of birth and sex" do
    sign_in("registration_menu")
    header = { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", mrn: "1001" }
    RpmsRpc::Patient.singleton_class.alias_method(:__brief_header, :brief_header)
    RpmsRpc::Patient.define_singleton_method(:brief_header) { |dfn| dfn == 3 ? header : nil }

    get "/lakeraven-ehr/registration/patients/3"

    assert_response :ok
    assert_select "h1", text: "MOUSE,MICKEY M"
    assert_select "[data-field='hrn']", text: "1001"
    assert_select "[data-field='dob']", text: "Feb 14, 1910"

    get "/lakeraven-ehr/registration/patients/99999"

    assert_response :not_found
    assert_select "#no-such-patient", text: /There is no patient with that identifier/
  ensure
    RpmsRpc::Patient.singleton_class.alias_method(:brief_header, :__brief_header)
    RpmsRpc::Patient.singleton_class.remove_method(:__brief_header)
  end
end
