# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-20 and S-REG-21: the front desk keeps a registered patient's
# demographics, address and phones current. RPMS decides what is filed (AG's
# update, after AG's own checks, RpmsRpc::Patient.update); these tests stand in
# for it at the gem boundary and check what the screens send and show.
class RegistrationEditPatientTest < ActionDispatch::IntegrationTest
  DFN = 990_031

  RECORD = {
    dfn: DFN, name: "EMBER,AVERY", dob: Date.new(1997, 3, 15), dob_text: "MAR 15,1997",
    name_last: "EMBER", name_first: "AVERY", ssn: "666321031", ssn_verification: "Pending Verification",
    sex: { internal: "F", external: "FEMALE" }, marital_status: { internal: "2", external: "MARRIED" },
    hrn: "990031", birth_city: nil, birth_state: nil, employer: nil, employment_status: nil,
    religion: { internal: "1", external: "CATHOLIC" },
    address_line1: "317 DUNEGRASS ST", address_line2: nil, address_line3: nil, city: "ANYWHERE",
    state: { internal: "27", external: "MONTANA" }, zip: "59000", phone_home: "406-555-1031",
    phone_work: nil, phone_other: nil, community: nil
  }.freeze
  HEADER = { name: "EMBER,AVERY", dob: Date.new(1997, 3, 15), sex: "F", mrn: "990031" }.freeze
  CONTACT = { dfn: DFN, phone_home: "406-555-1031", phone_work: nil, phone_cell: "406-555-2000", phone_other: nil, email: "avery@example.test" }.freeze
  PICKS = { marital_status: [ { ien: 2, name: "MARRIED" }, { ien: 6, name: "NEVER MARRIED" } ],
            religion: [ { ien: 1, name: "CATHOLIC" } ], state: [ { ien: 27, name: "MONTANA" } ],
            employer: [ { ien: 1, name: "EXAMPLE EMPLOYER" } ] }.freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  def stub(receiver, name, &body)
    restores = (@restores ||= [])
    restores << StubHelpers.install_singleton_stub(receiver, name, nil)
    receiver.define_singleton_method(name, &body)
  end

  # RPMS as the gem answers: the record, the contact read, the pick lists, and
  # the update, which answers from the script and records what it was sent.
  def with_rpms(*update_replies, record: RECORD, history: [])
    updates = []
    stub(RpmsRpc::Registration, :address_history) { |_dfn| history }
    # A change of address goes through change_address, which keeps the old one (S-REG-21.1).
    stub(RpmsRpc::Registration, :change_address) do |dfn, moved_on:, **attrs|
      updates << [ dfn, attrs.merge(moved_on: moved_on) ]
      update_replies.shift
    end
    stub(RpmsRpc::Patient, :brief_header) { |_dfn| HEADER }
    stub(RpmsRpc::Patient, :registration_record) { |dfn| dfn.to_i == DFN ? record : nil }
    stub(RpmsRpc::Patient, :contact) { |_dfn| CONTACT }
    stub(RpmsRpc::Registration, :pick_list) { |attribute, **| PICKS.fetch(attribute) }
    stub(RpmsRpc::Patient, :update) do |dfn, **attrs|
      updates << [ dfn, attrs ]
      update_replies.shift
    end
    yield updates
  ensure
    @restores&.reverse_each(&:call)
    @restores = nil
  end

  def saved = { success: true, dfn: DFN }

  def demographics(**changes)
    { name: "EMBER,AVERY", dob: "1997-03-15", sex: "F", marital_status: "2", religion: "1", birth_city: "",
      birth_state: "", employer: "", employment_status: "", ssn: "" }.merge(changes)
  end

  def address(**changes)
    { address_line1: "317 DUNEGRASS ST", address_line2: "", address_line3: "", city: "ANYWHERE", state: "27",
      zip: "59000", phone_home: "406-555-1031", phone_work: "", phone_other: "", email: "avery@example.test" }.merge(changes)
  end

  test "S-REG-20.1 the patient page shows the full registration, with an edit for each section" do
    sign_in("registration_menu")
    with_rpms do
      get "/lakeraven-ehr/registration/patients/#{DFN}"

      assert_response :success
      assert_select "#demographics [data-field='religion']", text: "Catholic"
      assert_select "#demographics [data-field='marital_status']", text: "Married"
      assert_select "#address [data-field='mailing_address']", text: /317 DUNEGRASS ST.*ANYWHERE MONTANA 59000/m
      assert_select "#address [data-field='email']", text: "avery@example.test"
      assert_select "a#edit-demographics[href=?]", "/lakeraven-ehr/registration/patients/#{DFN}/demographics/edit"
      assert_select "a#edit-address[href=?]", "/lakeraven-ehr/registration/patients/#{DFN}/address/edit"
    end
  end

  test "S-REG-20.1 only what changed is sent, and the patient page says it was saved" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/demographics",
            params: { demographics: demographics(dob: "1997-03-16", marital_status: "6", religion: "", employer: "1",
                                                 employment_status: "FULL-TIME", birth_city: "Springfield", birth_state: "27") }

      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal [ [ DFN, { dob: Date.new(1997, 3, 16), marital_status: "6", religion: "", birth_city: "SPRINGFIELD",
                              birth_state: "27", employer: "1", employment_status: "FULL-TIME" } ] ], updates
      follow_redirect!
      assert_select "#registration-notice", text: /Demographics saved\./
    end
  end

  test "S-REG-20.5 an employer with no employment status is refused, and RPMS is not asked" do
    sign_in("registration_menu")
    with_rpms do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/demographics", params: { demographics: demographics(employer: "1") }

      assert_response :unprocessable_content
      assert_select "#demographics-errors", text: /Employment status is required when there is an employer/
      assert_empty updates
    end
  end

  test "S-REG-20.7 a social security number RPMS refuses shows RPMS's reason and keeps the form" do
    sign_in("registration_menu")
    refusal = { success: false, error: :agg_invalid, field: :ssn, message: "SSN already used by another patient." }
    with_rpms(refusal) do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/demographics", params: { demographics: demographics(ssn: "666-01-0101") }

      assert_response :unprocessable_content
      assert_equal [ [ DFN, { ssn: "666010101" } ] ], updates
      assert_select "#demographics-alert", text: /SSN already used by another patient\./
      assert_select "#demographics-errors", text: /SSN already used by another patient\./
    end
  end

  test "S-REG-20.8 the social security number shows its last four digits only, and the form never carries it" do
    sign_in("registration_menu")
    with_rpms do
      get "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_select "#demographics [data-field='ssn']", text: "XXX-XX-1031"
      refute_includes response.body, "666321031"

      get "/lakeraven-ehr/registration/patients/#{DFN}/demographics/edit"
      assert_response :success
      refute_includes response.body, "666321031"
    end
  end

  test "S-REG-20.9 a view-only user sees the registration and can change nothing" do
    sign_in("registration_view_only")
    with_rpms do |updates|
      get "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_response :success
      assert_select "#demographics"
      assert_select "a#edit-demographics", count: 0
      assert_select "a#edit-address", count: 0

      get "/lakeraven-ehr/registration/patients/#{DFN}/demographics/edit"
      assert_response :forbidden
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(phone_home: "406-555-0101") }
      assert_response :forbidden
      assert_empty updates
    end
  end

  test "S-REG-20.10 a misspelled name is corrected in place" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/demographics", params: { demographics: demographics(name: "Embers,Avery") }

      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal [ [ DFN, { name: "EMBERS,AVERY" } ] ], updates
    end
  end

  test "S-REG-21.1 a new address and home phone are sent to RPMS" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address",
            params: { address: address(address_line1: "12 Example Rd", zip: "59001", phone_home: "406-555-0142") }

      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal [ [ DFN, { address_line1: "12 EXAMPLE RD", zip: "59001", phone_home: "406-555-0142", moved_on: Date.current } ] ],
                   updates
    end
  end

  test "S-REG-21.1 a new address is sent with the date the patient moved, so RPMS keeps the old one" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates|
      get "/lakeraven-ehr/registration/patients/#{DFN}/address/edit"
      assert_select "input[type=date][name='address[moved_on]'][value=?]", Date.current.iso8601

      patch "/lakeraven-ehr/registration/patients/#{DFN}/address",
            params: { address: address(city: "Elsewhere", moved_on: "2026-10-01") }

      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal [ [ DFN, { city: "ELSEWHERE", moved_on: Date.new(2026, 10, 1) } ] ], updates
    end
  end

  test "S-REG-21.1 the date moved defaults to RPMS's today and may not pass it, when the app's clock is a day ahead (#1065)" do
    sign_in("registration_menu")
    rpms_today = Date.current - 1
    Lakeraven::EHR::SiteDate.reader = -> { rpms_today }
    with_rpms(saved) do |updates|
      get "/lakeraven-ehr/registration/patients/#{DFN}/address/edit"
      assert_select "input[type=date][name='address[moved_on]'][value=?][max=?]", rpms_today.iso8601, rpms_today.iso8601

      patch "/lakeraven-ehr/registration/patients/#{DFN}/address",
            params: { address: address(city: "Elsewhere", moved_on: Date.current.iso8601) }
      assert_response :unprocessable_content
      assert_select "#address-errors", text: /Date they moved cannot be in the future/

      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(city: "Elsewhere") }
      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal [ [ DFN, { city: "ELSEWHERE", moved_on: rpms_today } ] ], updates
    end
  ensure
    Lakeraven::EHR::SiteDate.reader = -> { Date.current }
  end

  test "S-REG-21.1 the patient page lists the previous addresses with the dates lived there" do
    sign_in("registration_menu")
    history = [ { ien: 2, changed_on: Date.new(2026, 11, 3), line1: "317 DUNEGRASS ST", line2: "", line3: "", city: "ANYWHERE",
                  state: "MONTANA", zip: "59000", phone: "406-555-1031", lived_from: Date.new(2020, 1, 1),
                  lived_to: Date.new(2026, 10, 1) } ]
    with_rpms(history: history) do
      get "/lakeraven-ehr/registration/patients/#{DFN}"

      assert_select "#address-history tr[data-address-history='2']", text: /317 DUNEGRASS ST.*ANYWHERE MONTANA 59000/m
      assert_select "#address-history [data-field='lived']", text: /Jan 1, 2020\s+to\s+Oct 1, 2026/
    end
  end

  test "S-REG-21.1 with no previous address the page says so" do
    sign_in("registration_menu")
    with_rpms do
      get "/lakeraven-ehr/registration/patients/#{DFN}"

      assert_select "#no-address-history", text: /No previous addresses on file/
    end
  end

  test "S-REG-21.7 a date moved in the future is refused before RPMS is asked" do
    sign_in("registration_menu")
    with_rpms do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address",
            params: { address: address(city: "Elsewhere", moved_on: (Date.current + 1).iso8601) }

      assert_response :unprocessable_content
      assert_select "#address-errors", text: /Date they moved cannot be in the future/
      assert_empty updates
    end
  end

  test "S-REG-21.1 when the address is saved and its history is not, the clerk is told both" do
    sign_in("registration_menu")
    partial = { success: false, error: :partial, message: "The address was saved, but the previous address was not kept: refused" }
    with_rpms(partial) do
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(city: "Elsewhere") }

      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal partial[:message], flash[:alert]
    end
  end

  test "S-REG-21.4 a zip RPMS refuses shows RPMS's reason" do
    sign_in("registration_menu")
    refusal = { success: false, error: :agg_invalid, field: :zip, message: "Enter 5 or 9 digit zip code." }
    with_rpms(refusal) do
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(zip: "5900") }

      assert_response :unprocessable_content
      assert_select "#address-alert", text: /Enter 5 or 9 digit zip code\./
    end
  end

  test "S-REG-21.4 a phone shorter than 4 characters is refused before RPMS is asked" do
    sign_in("registration_menu")
    with_rpms do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(phone_work: "123") }

      assert_response :unprocessable_content
      assert_select "#address-errors", text: /Work phone must be 4 to 20 characters/
      assert_empty updates
    end
  end

  test "S-REG-21.5 S-REG-21.6 work phone, other phone and email are sent; an email not in email form is refused" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates|
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(email: "avery-at-example") }
      assert_response :unprocessable_content
      assert_empty updates

      patch "/lakeraven-ehr/registration/patients/#{DFN}/address",
            params: { address: address(phone_work: "406-555-0143", phone_other: "406-555-0144", email: "new@example.test") }
      assert_equal [ [ DFN, { phone_work: "406-555-0143", phone_other: "406-555-0144", email: "new@example.test" } ] ], updates
    end
  end

  test "when RPMS does not answer, the clerk is told the outcome is unknown" do
    sign_in("registration_menu")
    with_rpms(nil) do
      patch "/lakeraven-ehr/registration/patients/#{DFN}/address", params: { address: address(phone_home: "406-555-0101") }

      assert_response :service_unavailable
      assert_select "#address-alert", text: /did not say whether the change was saved/
    end
  end

  test "a patient RPMS has no record of is not found" do
    sign_in("registration_menu")
    with_rpms do
      get "/lakeraven-ehr/registration/patients/12345/demographics/edit"

      assert_response :not_found
    end
  end
end
