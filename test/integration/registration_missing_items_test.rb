# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-23 and S-REG-31.1: the patient's registration lists what is
# missing or wrong on it, by section, errors counted apart from warnings: AG's
# own edit checks (AGG PATIENT EDIT CHECK), read through RpmsRpc::Agg.
class RegistrationMissingItemsTest < ActionDispatch::IntegrationTest
  RS = "\x1e"
  US = "\x1f"
  HEADER = "I00010HIDE_ERROR_NUM^T00030MSG^T00001TYPE^T00030HIDE_WINDOW^T00008HIDE_FIELD^T00050HIDE_TAB^T00001HIDE_KEY"

  # What AG answered, live on the 7c3119b build, for a patient registered with
  # the minimum (name, sex, date of birth, reason for no SSN, tribe, community).
  MINIMUM = [
    "37^INTERNET ACCESS INFORMATION PAST ONE YEAR^WARNING^Other Patient^AGGINTNT^OtherPatientData^O",
    "39^Patient's Migrant Worker information incomplete^WARNING^Other Patient^AGGMGSTS^OtherPatientData^O",
    "40^Patient's Homeless information incomplete^WARNING^Other Patient^AGGHMSTS^OtherPatientData^O",
    "41^Patient's Primary Language, Proficiency or Interpreter Required incomplete^WARNING^Other Patient^AGGLGPRI^OtherPatientData^O",
    "49^Patient's Preferred Language incomplete or not in patient's list of languages^ERROR^Other Patient^AGGLGPRF^OtherPatientData^O",
    "51^Patient's Ethnicity/Method of Collection incomplete^ERROR^Other Patient^AGETH^OtherPatientData^O",
    "52^Patient's RACE incomplete^ERROR^Other Patient^AGRACE^OtherPatientData^O",
    "805^missing INDIAN QUANTUM^MANDATORY^Eligibility^AGGPTBLQ^FamilyDetail^B",
    "807^missing BENEFICIARY^MANDATORY^Eligibility^AGGPTCLB^FamilyDetail^B",
    "808^invalid ELIGIBILITY &/OR CLASS/TRIBE/QUANTUM DEMOGRAPHICS^MANDATORY^Eligibility^AGGPTELG^FamilyDetail^B"
  ].freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  def seed_checks(rows)
    RpmsRpc.client.seed(:agg_patient_edit_check, "3", ([ HEADER ] + rows).map { |r| "#{r}#{RS}" }.join + US)
  end

  def edit_checks_asked
    RpmsRpc.client.received_calls.count { |c| c[:rpc] == "AGG PATIENT EDIT CHECK" }
  end

  setup do
    header = { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", mrn: "1001" }
    RpmsRpc::Patient.singleton_class.alias_method(:__brief_header, :brief_header)
    RpmsRpc::Patient.define_singleton_method(:brief_header) { |dfn| dfn == 3 ? header : nil }
  end

  teardown do
    RpmsRpc::Patient.singleton_class.alias_method(:brief_header, :__brief_header)
    RpmsRpc::Patient.singleton_class.remove_method(:__brief_header)
  end

  test "S-REG-23.1 and S-REG-31.1 each item is listed under its section, errors counted apart from warnings" do
    sign_in("registration_menu")
    seed_checks(MINIMUM)

    get "/lakeraven-ehr/registration/patients/3"

    assert_response :ok
    assert_select "#missing-items-counts [data-count='errors']", text: "6"
    assert_select "#missing-items-counts [data-count='warnings']", text: "4"
    assert_select "#missing-items h3[data-section='other-patient-information']", text: "Other patient information"
    assert_select "#missing-items h3[data-section='eligibility-and-tribe']", text: "Eligibility and tribe"
    assert_select "#missing-items li[data-check='807'][data-kind='error']", text: /Error\s+missing BENEFICIARY/
    assert_select "#missing-items li[data-check='40'][data-kind='warning']", text: /Warning\s+Patient's Homeless information incomplete/
  end

  test "S-REG-23.2 an item RPMS no longer lists is gone from the page" do
    sign_in("registration_menu")
    seed_checks(MINIMUM.reject { |row| row.start_with?("807^") })

    get "/lakeraven-ehr/registration/patients/3"

    assert_select "#missing-items li[data-check='807']", count: 0
    assert_select "#missing-items-counts [data-count='errors']", text: "5"
  end

  test "S-REG-31.2 and 31.3 a registration AG finds nothing missing on says it is complete" do
    sign_in("registration_menu")
    seed_checks([])

    get "/lakeraven-ehr/registration/patients/3"

    assert_select "#missing-items-none", text: /Nothing is missing/
    assert_select "#missing-items li", count: 0
  end

  test "a list RPMS does not answer is never shown as complete" do
    sign_in("registration_menu")

    get "/lakeraven-ehr/registration/patients/3"

    assert_response :ok
    assert_select "#missing-items-unavailable", text: /RPMS did not say what is missing/
    assert_select "#missing-items-none", count: 0
  end

  # AG's checks run in its registration context, which RPMS refuses a
  # scheduler, so a scheduler's view of the registration does not ask.
  test "a scheduler opening a registration is not shown the list, and RPMS is not asked" do
    sign_in("scheduling_user")
    before = edit_checks_asked

    get "/lakeraven-ehr/registration/patients/3"

    assert_response :ok
    assert_select "#missing-items", count: 0
    assert_equal before, edit_checks_asked
  end
end
