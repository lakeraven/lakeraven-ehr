# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-07.2, 07.3, 07.8 and 07.9. RpmsRpc::PatientProfile and
# RpmsRpc::Registration check and file; these tests stand in for them at the gem
# boundary and check what the screens send and show.
class RegistrationTribesTest < ActionDispatch::IntegrationTest
  include BrowserFormHelper
  include PatientProfileStubs

  TRIBE = { ien: 1, tribe_ien: 5, tribe: "NATIVE VILLAGE OF BELKOFSKI", quantum: "1/8" }.freeze
  REASON = { ien: 12, name: "A REASON" }.freeze

  def with_status(status)
    StubHelpers.with_stub(RpmsRpc::Tribal, :enrollment, { eligibility_status: status }) { yield }
  end

  test "S-REG-07.2 and 07.3 the patient's page lists other tribes and reasons" do
    sign_in
    with_profile(other_tribes: ->(*) { [ TRIBE ] }, eligibility_modifiers: ->(*) { [ REASON ] }) do
      get BASE
    end

    assert_select "#other-tribes-section [data-other-tribe='1']", text: /1\/8/
    assert_select "#other-tribes-section [data-modifier='12']", text: "A REASON"
  end

  test "S-REG-07.2 another tribe is added with its quantum" do
    sign_in
    with_profile(add_other_tribe: ->(*, **) { { success: true } }) do |calls|
      post "#{BASE}/other_tribes", params: { other_tribe: { tribe_ien: 5, quantum: "1/8" } }

      assert_redirected_to "#{BASE}/other_tribes"
      assert_equal({ tribe: 5, quantum: "1/8" }, sent(calls, :add_other_tribe).sole[2])
    end
  end

  test "S-REG-07.2 a quantum out of form, or no tribe, files nothing" do
    sign_in
    with_profile do |calls|
      post "#{BASE}/other_tribes", params: { other_tribe: { tribe_ien: 5, quantum: "half" } }
      assert_response :unprocessable_content
      assert_select "#other-tribe-errors", text: /fraction like 1\/4/

      post "#{BASE}/other_tribes", params: { other_tribe: { quantum: "1/8" } }
      assert_select "#other-tribe-errors", text: /find the tribe/
      assert_empty sent(calls, :add_other_tribe)
    end
  end

  test "S-REG-07.8 and 07.9 RPMS's refusal shows against the field" do
    sign_in
    refusal = { success: false, error: :invalid, field: :quantum, message: "Sum of Tribe and Other Tribe Quantums is greater than the Indian Blood Quantum" }
    with_profile(add_other_tribe: ->(*, **) { refusal }) do
      post "#{BASE}/other_tribes", params: { other_tribe: { tribe_ien: 5, quantum: "1/2" } }
    end

    assert_response :unprocessable_content
    assert_select "#other-tribe-errors", text: /greater than the Indian Blood Quantum/
  end

  test "S-REG-07.3 a reason is added, offered only for the status, and not twice" do
    sign_in
    with_status("C") do
      with_profile(eligibility_modifiers: ->(*) { [ REASON ] },
                   eligibility_modifier_choices: ->(status) { status == "C" ? [ REASON, { ien: 13, name: "ANOTHER" } ] : [] },
                   add_eligibility_modifier: ->(*) { { success: true } }) do |calls|
        get "#{BASE}/eligibility_modifiers"
        assert_select "#modifier_ien option[value='13']"
        assert_select "#modifier_ien option[value='12']", 0

        post "#{BASE}/eligibility_modifiers", params: { modifier_ien: 13 }
        assert_redirected_to "#{BASE}/eligibility_modifiers"
        assert_equal [ DFN, 13 ], sent(calls, :add_eligibility_modifier).sole[1]
      end
    end
  end

  test "S-REG-07.3 with no eligibility status, no reason is offered" do
    sign_in
    with_status(nil) do
      with_profile do
        get "#{BASE}/eligibility_modifiers"

        assert_select "#no-eligibility-status"
        assert_select "#eligibility-modifier-form", 0
      end
    end
  end

  test "a user who may read the registration but not change it files nothing" do
    sign_in("")
    with_profile do |calls|
      post "#{BASE}/other_tribes", params: { other_tribe: { tribe_ien: 5 } }
      post "#{BASE}/eligibility_modifiers", params: { modifier_ien: 13 }

      assert_empty sent(calls, :add_other_tribe)
      assert_empty sent(calls, :add_eligibility_modifier)
    end
  end
end
