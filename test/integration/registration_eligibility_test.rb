# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-07.1: the front desk records a patient's tribe, blood quantum
# and eligibility on IHS PATIENT through AG's Eligibility window
# (RpmsRpc::Patient.update). RPMS is stood in for at the gem boundary;
# test/integration/live_registration_eligibility_test.rb runs it for real.
class RegistrationEligibilityTest < ActionDispatch::IntegrationTest
  DFN = 990_052
  RECORD = { dfn: DFN, name: "BRAVO,REESE", dob: Date.new(1948, 5, 19), sex: { internal: "M", external: "MALE" } }.freeze
  ENROLLMENT = { enrollment_number: "ZZ1", tribe_ien: 532, tribe_name: "KWETHLUK, ORGANIZED VILLAGE OF KWETHLUK",
                 tribe_quantum: "1/4", indian_blood_quantum: "1/2", classification_ien: 2,
                 classification: "INDIAN/ALASKA NATIVE", eligibility_status: "C", community: "NORTH LANDING" }.freeze
  CLASSIFICATIONS = [ { ien: "2", pieces: [ "INDIAN/ALASKA NATIVE" ] }, { ien: "1", pieces: [ "OTHER" ] } ].freeze

  def sign_in(keys) = post("/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys })

  def path = "/lakeraven-ehr/registration/patients/#{DFN}/eligibility"

  def stub(receiver, name, &body)
    (@restores ||= []) << StubHelpers.install_singleton_stub(receiver, name, nil)
    receiver.define_singleton_method(name, &body)
  end

  def with_rpms(*update_replies)
    updates = []
    stub(RpmsRpc::Patient, :registration_record) { |_dfn| RECORD }
    stub(RpmsRpc::Patient, :contact) { |_dfn| {} }
    stub(RpmsRpc::Tribal, :enrollment) { |_dfn| ENROLLMENT }
    stub(RpmsRpc::Tribal, :tribes) { |part: nil, **| part.to_s.start_with?("KW") ? [ { ien: 532, name: ENROLLMENT[:tribe_name] } ] : [] }
    stub(RpmsRpc::DdrFileman, :lister) { |**| { entries: CLASSIFICATIONS, error: false } }
    stub(RpmsRpc::Patient, :update) do |dfn, **attrs|
      updates << [ dfn, attrs ]
      update_replies.shift
    end
    yield updates
  ensure
    @restores&.reverse_each(&:call)
    @restores = nil
  end

  def form(**changes)
    { eligibility_status: "C", classification_ien: "2", tribe_ien: "532", blood_quantum: "1/2", tribe_quantum: "1/4",
      enrollment_number: "ZZ1" }.merge(changes)
  end

  test "S-REG-07.1 the form shows the patient's tribal standing as RPMS holds it" do
    sign_in("registration_menu")
    with_rpms { get "#{path}/edit" }

    assert_response :ok
    assert_select "input[name='eligibility[eligibility_status]'][value='C'][checked]"
    assert_select "select[name='eligibility[classification_ien]'] option[selected][value='2']", text: "INDIAN/ALASKA NATIVE"
    assert_select "input[name='eligibility[tribe_ien]'][value='532']"
    assert_select "input[name='eligibility[blood_quantum]'][value='1/2']"
    assert_select "input[name='eligibility[enrollment_number]'][value='ZZ1']"
  end

  test "S-REG-07.1 only what changed is sent to AG, under AG's attribute names" do
    sign_in("registration_menu")
    with_rpms({ success: true, dfn: DFN }) do |updates|
      patch path, params: { eligibility: form(blood_quantum: "3/4", tribe_quantum: "", enrollment_number: "zz4901"), commit: "Save" }

      assert_redirected_to "/lakeraven-ehr/registration/patients/#{DFN}"
      assert_equal [ [ DFN, { blood_quantum: "3/4", tribe_quantum: "", enrollment_number: "ZZ4901" } ] ], updates
    end
  end

  test "a quantum that is not a fraction is refused before RPMS is asked" do
    sign_in("registration_menu")
    with_rpms do |updates|
      patch path, params: { eligibility: form(blood_quantum: "half"), commit: "Save" }

      assert_response :unprocessable_content
      assert_select "#eligibility-errors", text: /Indian blood quantum must be a fraction/
      assert_empty updates
    end
  end

  test "when AG refuses, its reason is shown and the form keeps what was typed" do
    sign_in("registration_menu")
    with_rpms({ success: false, error: :agg_rejected, window: "Eligibility", message: "Ben/Class selected should be Eligible for care" }) do
      patch path, params: { eligibility: form(eligibility_status: "I"), commit: "Save" }
    end

    assert_response :unprocessable_content
    assert_select "#eligibility-alert", text: /Ben\/Class selected should be Eligible for care/
    assert_select "input[name='eligibility[eligibility_status]'][value='I'][checked]"
  end

  test "Find tribe shows the matches without saving" do
    sign_in("registration_menu")
    with_rpms do |updates|
      patch path, params: { eligibility: form, tribe_search: "KW" }

      assert_response :ok
      assert_select "label[data-tribe='532']"
      assert_empty updates
    end
  end

  test "a view-only user cannot open or save the form" do
    sign_in("registration_view_only")
    with_rpms do |updates|
      get "#{path}/edit"
      assert_response :forbidden
      patch path, params: { eligibility: form(blood_quantum: "3/4"), commit: "Save" }
      assert_response :forbidden
      assert_empty updates
    end
  end
end
