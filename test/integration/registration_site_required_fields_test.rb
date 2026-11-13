# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#980: the registration forms require exactly the fields the
# site has set as mandatory in RPMS, REGISTRATION PARAMETERS (#9009061) field
# 1101 MANDATORY FIELDS (SITE). The settings below have the shape
# RpmsRpc::RegistrationParameters.for_facility answered on a live build
# (bcer-9.0, division 7819); the RPMS side of these tests stands in at the gem
# boundary, as in RegistrationEditPatientTest. The same behaviour is proven
# on a real RPMS in LiveRegistrationSiteRequiredFieldsTest.
class RegistrationSiteRequiredFieldsTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  RECORD = {
    dfn: DFN, name: "HOTEL,DREW", dob: Date.new(1982, 11, 8), sex: { internal: "M", external: "MALE" },
    address_line1: "1 EXAMPLE RD", address_line2: nil, address_line3: nil, city: "ANYWHERE",
    state: { internal: "27", external: "MONTANA" }, zip: "59000", phone_home: nil, phone_work: nil, phone_other: nil
  }.freeze

  def settings(*rows)
    Lakeraven::EHR::RegistrationSiteSettings.new(
      { facility: 7819, on_file: true, switches: {},
        mandatory_fields: rows.map { |file, field, required| { file: file, field: field, required: required } } }
    )
  end

  HOME_PHONE_AND_PREFERRED = [ [ "2", "PHONE NUMBER [RESIDENCE]", true ], [ "9000001", "PREFERRED LANGUAGE", true ],
                               [ "9000001", "PRIMARY LANGUAGE", false ] ].freeze

  # RPMS as the gem answers for the address form; returns what was sent to update.
  def with_address_rpms(site)
    updates = []
    restores = [
      StubHelpers.install_singleton_stub(Lakeraven::EHR::RegistrationSettingsGateway, :current, site),
      StubHelpers.install_singleton_stub(RpmsRpc::Patient, :registration_record, RECORD),
      StubHelpers.install_singleton_stub(RpmsRpc::Patient, :contact, { dfn: DFN }),
      StubHelpers.install_singleton_stub(RpmsRpc::Patient, :brief_header, HEADER),
      StubHelpers.install_singleton_stub(RpmsRpc::Registration, :pick_list, [ { ien: 27, name: "MONTANA" } ])
    ]
    restores << StubHelpers.install_singleton_stub(RpmsRpc::Patient, :update, nil)
    RpmsRpc::Patient.define_singleton_method(:update) { |dfn, **attrs| (updates << [ dfn, attrs ]) && { success: true, dfn: dfn } }
    yield updates
  ensure
    restores&.reverse_each(&:call)
  end

  def address(**changes)
    { address_line1: "1 EXAMPLE RD", address_line2: "", address_line3: "", city: "ANYWHERE", state: "27", zip: "59000",
      phone_home: "", phone_work: "", phone_other: "", email: "" }.merge(changes)
  end

  test "a field the site requires is marked required on the form" do
    sign_in
    with_address_rpms(settings(*HOME_PHONE_AND_PREFERRED)) do
      get "#{BASE}/address/edit"

      assert_response :success
      assert_select "label[for='address_phone_home']", text: "Home phone (required)"
      assert_select "input#address_phone_home[required]"
      assert_select "label[for='address_phone_work']", text: "Work phone (optional)"
      assert_select "input#address_phone_work[required]", count: 0
    end
  end

  test "a save missing a field the site requires is refused, names it, and RPMS is not asked" do
    sign_in
    with_address_rpms(settings(*HOME_PHONE_AND_PREFERRED, [ "2", "CITY", true ])) do |updates|
      patch "#{BASE}/address", params: { address: address(city: "", phone_work: "406-555-0100") }

      assert_response :unprocessable_content
      assert_select "#address-errors", text: /Home phone is required by this site/
      assert_select "#address-errors", text: /City is required by this site/
      assert_empty updates
    end
  end

  test "a field the site lists as not required, or does not list, saves without it" do
    sign_in
    with_address_rpms(settings([ "2", "PHONE NUMBER [RESIDENCE]", false ])) do |updates|
      patch "#{BASE}/address", params: { address: address(phone_work: "406-555-0100") }

      assert_redirected_to BASE
      assert_equal [ [ DFN, { phone_work: "406-555-0100" } ] ], updates
    end
  end

  test "when the site's settings cannot be read the form says so and does not save" do
    sign_in
    with_address_rpms(Lakeraven::EHR::RegistrationSiteSettings.unavailable) do |updates|
      get "#{BASE}/address/edit"
      assert_select "#address-settings-unavailable", text: /Required fields could not be determined from RPMS/

      patch "#{BASE}/address", params: { address: address(phone_home: "406-555-0100") }

      assert_response :service_unavailable
      assert_select "#address-errors", text: /Required fields could not be determined from RPMS\. Nothing was saved\./
      assert_empty updates
    end
  end

  test "a preferred language the site requires is refused when missing, by name" do
    sign_in
    restore = StubHelpers.install_singleton_stub(Lakeraven::EHR::RegistrationSettingsGateway, :current,
                                                 settings(*HOME_PHONE_AND_PREFERRED))
    with_profile do |calls|
      get "#{BASE}/languages/edit"
      assert_select "legend", text: "Preferred language (required)"

      post "#{BASE}/languages", params: { languages: { primary_ien: SPANISH, interpreter: "Y" } }

      assert_response :unprocessable_content
      assert_select "#languages-errors", text: /Preferred language is required by this site/
      assert_empty sent(calls, :record_languages)
    end
  ensure
    restore&.call
  end

  test "the SSN a site requires is answered by a number or by the reason there is none" do
    sign_in
    restores = [
      StubHelpers.install_singleton_stub(Lakeraven::EHR::RegistrationSettingsGateway, :current,
                                         settings([ "2", "SOCIAL SECURITY NUMBER", true ])),
      StubHelpers.install_singleton_stub(Lakeraven::EHR::PatientRegistrationGateway, :tribes, []),
      StubHelpers.install_singleton_stub(Lakeraven::EHR::PatientRegistrationGateway, :communities, [])
    ]
    entry = { name: "HOTEL,DREW", sex: "M", dob: "1982-11-08", tribe_ien: "1", community_ien: "1" }

    post "/lakeraven-ehr/registration/patients", params: { registration: entry, submission_id: SecureRandom.uuid }
    assert_response :unprocessable_content
    assert_select "#registration-errors", text: /Social security number is required by this site/

    registration = Lakeraven::EHR::PatientRegistration.new(entry.merge(no_ssn_reason: "R"))
    registration.site_settings = settings([ "2", "SOCIAL SECURITY NUMBER", true ])
    assert registration.valid?, registration.errors.full_messages.inspect
  ensure
    restores&.reverse_each(&:call)
  end
end
