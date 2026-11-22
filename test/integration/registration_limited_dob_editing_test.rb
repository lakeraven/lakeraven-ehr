# frozen_string_literal: true

require "test_helper"

# Synthetic RPMS responses exercise the existing-patient form at the gem boundary.
class RegistrationLimitedDobEditingTest < ActionDispatch::IntegrationTest
  DFN = 990_031
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}"
  RECORD = {
    dfn: DFN, name: "EMBER,AVERY", dob: Date.new(1997, 3, 15), sex: { internal: "F", external: "FEMALE" },
    marital_status: { internal: "2", external: "MARRIED" }, religion: { internal: "1", external: "CATHOLIC" },
    birth_city: nil, birth_state: nil, employer: nil, employment_status: nil
  }.freeze
  HEADER = { name: "EMBER,AVERY", dob: Date.new(1997, 3, 15), sex: "F", mrn: "990031" }.freeze
  PICKS = { marital_status: [ { ien: 2, name: "MARRIED" } ], religion: [ { ien: 1, name: "CATHOLIC" } ],
            state: [ { ien: 27, name: "MONTANA" } ], employer: [] }.freeze

  def sign_in(keys = "registration_menu")
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  def settings(value)
    Lakeraven::EHR::RegistrationSiteSettings.new({ facility: 7819, on_file: true,
      switches: { limited_dob_editing: value }, mandatory_fields: [] })
  end

  def with_rpms(site, record: RECORD)
    updates = []
    restores = []
    install = lambda do |receiver, method, &body|
      restores << StubHelpers.install_singleton_stub(receiver, method, nil)
      receiver.define_singleton_method(method, &body)
    end
    install.call(Lakeraven::EHR::RegistrationSettingsGateway, :current) { site.respond_to?(:call) ? site.call : site }
    install.call(RpmsRpc::Patient, :registration_record) { |_dfn| record.respond_to?(:call) ? record.call : record }
    install.call(RpmsRpc::Patient, :brief_header) { |_dfn| HEADER }
    install.call(RpmsRpc::Registration, :pick_list) { |attribute, **| PICKS.fetch(attribute) }
    install.call(RpmsRpc::Patient, :update) do |dfn, **attrs|
      updates << [ dfn, attrs ]
      { success: true, dfn: dfn }
    end
    yield updates
  ensure
    restores&.reverse_each(&:call)
  end

  def demographics(**changes)
    { name: "EMBER,AVERY", dob: "1997-03-15", sex: "F", marital_status: "2", religion: "1", birth_city: "",
      birth_state: "", employer: "", employment_status: "", ssn: "" }.merge(changes)
  end

  test "limited DOB is displayed noneditable with a manager explanation while other fields remain editable" do
    sign_in
    with_rpms(settings(true)) do
      get "#{BASE}/demographics/edit"
      assert_response :success
      assert_select "input[name='demographics[dob]'][value='1997-03-15'][disabled], input[name='demographics[dob]'][value='1997-03-15'][readonly]", count: 1
      assert_match(/registration manager/i, response.body)
      assert_select "input[name='demographics[name]']:not([disabled]):not([readonly])", count: 1
    end
  end

  test "a forged DOB change refuses the entire update" do
    sign_in
    with_rpms(settings(true)) do |updates|
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16", name: "EMBERS,AVERY") }
      assert_empty updates
      assert_response :unprocessable_content
    end
  end

  test "a forged DOB change explains the field-level refusal" do
    sign_in
    with_rpms(settings(true)) do
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16") }
      assert_select "#demographics-errors", text: /date of birth.*manager/i
    end
  end

  test "a rejected DOB change records a safe audit denial reason" do
    sign_in
    with_rpms(settings(true)) do
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16", name: "EMBERS,AVERY") }
      denial = Lakeraven::EHR::AuditEvent.order(:id).last&.outcome_desc.to_s
      assert_match(/(dob|date of birth).* (refus|deni|manager|authoriz)|(?:refus|deni|manager|authoriz).*\b(dob|date of birth)/i, denial)
      %w[1997-03-15 1997-03-16 EMBER AVERY].each { |phi| refute_includes denial, phi }
    end
  end

  test "omitted DOB uses the record loaded for this request and sends only the other change" do
    sign_in
    current = RECORD
    with_rpms(settings(true), record: -> { current }) do |updates|
      get "#{BASE}/demographics/edit"
      assert_response :success
      current = RECORD.merge(dob: Date.new(1996, 2, 10))
      attrs = demographics(name: "EMBERS,AVERY").except(:dob)
      patch "#{BASE}/demographics", params: { demographics: attrs }
      assert_redirected_to BASE
      assert_equal [ [ DFN, { name: "EMBERS,AVERY" } ] ], updates
    end
  end

  test "same DOB allows other changes under the restriction" do
    sign_in
    with_rpms(settings(true)) do |updates|
      patch "#{BASE}/demographics", params: { demographics: demographics(name: "EMBERS,AVERY") }
      assert_redirected_to BASE
      assert_equal [ [ DFN, { name: "EMBERS,AVERY" } ] ], updates
    end
  end

  test "manager can correct DOB with the switch on" do
    sign_in("registration_manager")
    with_rpms(settings(true)) do |updates|
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16") }
      assert_redirected_to BASE
      assert_equal [ [ DFN, { dob: Date.new(1997, 3, 16) } ] ], updates
    end
  end

  test "view-only remains denied even with manager key" do
    sign_in("registration_manager registration_view_only")
    with_rpms(settings(true)) do |updates|
      get "#{BASE}/demographics/edit"
      assert_response :forbidden
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16") }
      assert_response :forbidden
      assert_empty updates
    end
  end

  test "false and unanswered switches allow a clerk to change DOB" do
    sign_in
    [ false, nil ].each do |value|
      with_rpms(settings(value)) do |updates|
        patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16") }
        assert_redirected_to BASE
        assert_equal [ [ DFN, { dob: Date.new(1997, 3, 16) } ] ], updates
      end
    end
  end

  test "unavailable settings refuse a save with no patient write" do
    sign_in
    with_rpms(Lakeraven::EHR::RegistrationSiteSettings.unavailable) do |updates|
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16") }
      assert_response :service_unavailable
      assert_empty updates
    end
  end

  test "settings are re-read on PATCH after the switch changes" do
    sign_in
    site = settings(false)
    with_rpms(-> { site }) do |updates|
      get "#{BASE}/demographics/edit"
      assert_response :success
      site = settings(true)
      patch "#{BASE}/demographics", params: { demographics: demographics(dob: "1997-03-16") }
      assert_empty updates
      assert_response :unprocessable_content
    end
  end
end
