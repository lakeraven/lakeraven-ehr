# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#981: the registration screens ask for a section only when the
# site's RPMS registration switches say so: REGISTRATION PARAMETERS
# (#9009061) fields 1 to 8, "Ask for ...". The settings below have the shape
# RpmsRpc::RegistrationParameters.for_facility answers; the build's demo
# division answers NO to every switch here, and LiveRegistrationSiteSwitchesTest
# proves the same screens on it. RPMS's other answers stand in at the gem
# boundary, as in RegistrationContactsTest.
class RegistrationSiteSwitchesTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  def switches(**values)
    Lakeraven::EHR::RegistrationSiteSettings.new({ facility: 7819, on_file: true, switches: values, mandatory_fields: [] })
  end

  def with_settings(settings, &block)
    StubHelpers.with_stub(Lakeraven::EHR::RegistrationSettingsGateway, :current, settings, &block)
  end

  def with_patient_page_rpms(&block)
    StubHelpers.with_stub(Lakeraven::EHR::RegistrationChecksGateway, :for, nil) do
      StubHelpers.with_stub(Lakeraven::EHR::PatientRecordGateway, :find, RECORD.merge(name: "HOTEL,DREW")) do
        with_profile(&block)
      end
    end
  end

  # -- identifiers: other names, other tribes, blood quantum, enrollment number --

  test "other names and other tribes a site does not ask for are not shown, and their pages say why" do
    sign_in
    with_settings(switches(other_names: false, other_tribes: false)) do
      with_patient_page_rpms do
        get BASE

        assert_response :ok
        assert_select "#other-names-section", count: 0
        assert_select "#other-tribes-section [data-field='other_tribes']", count: 0
        assert_select "#edit-other-tribes", count: 0
        # The eligibility reasons in the same section are not a switch of their own.
        assert_select "#other-tribes-section [data-field='eligibility_modifiers']"

        get "#{BASE}/other_names"
        assert_redirected_to BASE
        assert_equal "This site does not ask for other names: it is turned off in RPMS's registration settings.", flash[:alert]

        get "#{BASE}/other_tribes"
        assert_redirected_to BASE
      end
    end
  end

  test "other names and other tribes a site asks for are shown" do
    sign_in
    with_settings(switches(other_names: true, other_tribes: true)) do
      with_patient_page_rpms do
        get BASE

        assert_select "#other-names-section"
        assert_select "#other-tribes-section [data-field='other_tribes']"
        assert_select "#edit-other-tribes"
      end
    end
  end

  # -- contacts: next of kin --

  test "next of kin a site does not ask for is not shown or edited; the emergency contact still is" do
    sign_in
    with_settings(switches(next_of_kin: false)) do
      with_patient_page_rpms do |calls|
        get BASE
        assert_select "#contact-emergency"
        assert_select "#contact-next-of-kin", count: 0

        post "#{BASE}/contacts/next_of_kin", params: { contact: { name: "DOE,JOHN" } }
        assert_redirected_to BASE
        assert_empty sent(calls, :update_contact)
      end
    end
  end

  # -- coverage: Medicaid, private insurance --

  test "Medicaid and private insurance a site does not ask for are not offered, and their forms refuse" do
    sign_in
    with_settings(switches(medicaid: false, private_insurance: false)) do
      StubHelpers.with_stub(RpmsRpc::Patient, :brief_header, HEADER) do
        StubHelpers.with_stub(Lakeraven::EHR::CoverageGateway, :on_file, []) do
          StubHelpers.with_stub(RpmsRpc::PatientApplication, :for_patient, []) do
            get "#{BASE}/coverage"

            assert_response :ok
            assert_select "#add-medicare"
            assert_select "#add-medicaid", count: 0
            assert_select "#add-private", count: 0

            get "#{BASE}/coverage/new", params: { kind: "medicaid" }
            assert_redirected_to BASE
          end
        end
      end
    end
  end

  # -- when RPMS cannot be read: every section is asked --

  test "when the switches cannot be read every section is asked" do
    sign_in
    with_settings(Lakeraven::EHR::RegistrationSiteSettings.unavailable) do
      with_patient_page_rpms do
        get BASE

        assert_select "#other-names-section"
        assert_select "#other-tribes-section [data-field='other_tribes']"
        assert_select "#contact-next-of-kin"
      end
    end
  end

  test "a switch the site has not answered asks" do
    settings = Lakeraven::EHR::RegistrationSiteSettings.not_on_file(7819)

    assert(%i[blood_quantum enrollment_number other_names medicaid private_insurance next_of_kin other_tribes].all? { |s| settings.ask?(s) })
    refute settings.limited_dob_editing?
  end
end
