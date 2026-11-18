# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-17. RpmsRpc::Registration checks and files; these tests stand in
# for it at the gem boundary and check what the screens send and show.
# live_registration_advance_directives_test.rb files on a real RPMS.
class RegistrationAdvanceDirectivesTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  LIVING_WILL = { ien: 3, entered_on: Date.new(2026, 11, 2), directive: true, type_ien: 34, type: "LIVING WILL", reason: nil }.freeze
  NONE = { ien: 4, entered_on: Date.new(2026, 11, 9), directive: false, type_ien: nil, type: nil, reason: "PATIENT HAS NONE" }.freeze

  test "S-REG-17.1 and 17.2 the patient's page shows the newest answer, or none on file" do
    sign_in
    with_profile(advance_directives: ->(*) { [ NONE, LIVING_WILL ] }) do
      get BASE
    end
    assert_select "#advance-directives-section [data-field='advance_directive']", text: /No \(PATIENT HAS NONE\), 2026-11-09/

    with_profile do
      get BASE
    end
    assert_select "#advance-directives-section [data-field='advance_directive']", text: /None on file/
  end

  test "S-REG-17.1 a directive is sent with its type and date of entry" do
    sign_in
    with_profile(record_advance_directive: ->(*, **) { { success: true } }) do |calls|
      get "#{BASE}/advance_directives"
      assert_select "#advance_directive_type_ien option[value='34']", text: "LIVING WILL"
      assert_select "#no-advance-directives"

      post "#{BASE}/advance_directives",
           params: { advance_directive: { entered_on: "2026-11-02", directive: "Y", type_ien: "34", reason: "" } }

      assert_redirected_to "#{BASE}/advance_directives"
      _name, args, kwargs = sent(calls, :record_advance_directive).sole
      assert_equal [ DFN ], args
      assert_equal({ directive: true, type: 34, reason: nil, entered_on: Date.new(2026, 11, 2) }, kwargs)
    end
  end

  test "S-REG-17.2 no directive is sent with the reason, and a type left on the form is dropped" do
    sign_in
    with_profile(record_advance_directive: ->(*, **) { { success: true } }) do |calls|
      post "#{BASE}/advance_directives",
           params: { advance_directive: { entered_on: "2026-11-09", directive: "N", type_ien: "34", reason: " PATIENT HAS NONE " } }

      assert_redirected_to "#{BASE}/advance_directives"
      assert_equal({ directive: false, type: nil, reason: "PATIENT HAS NONE", entered_on: Date.new(2026, 11, 9) },
                   sent(calls, :record_advance_directive).sole[2])
    end
  end

  test "S-REG-17.4 no type, no reason, a short reason or no date is refused against the field, and nothing is sent" do
    sign_in
    with_profile do |calls|
      post "#{BASE}/advance_directives", params: { advance_directive: { entered_on: "2026-11-02", directive: "Y" } }
      assert_response :unprocessable_content
      assert_select "#advance-directive-errors", text: /Type/

      post "#{BASE}/advance_directives", params: { advance_directive: { entered_on: "2026-11-02", directive: "N", reason: "NO" } }
      assert_select "#advance-directive-errors", text: /Reason must be 3 to 30 characters/

      post "#{BASE}/advance_directives", params: { advance_directive: { directive: "N", reason: "PATIENT HAS NONE" } }
      assert_select "#advance-directive-errors", text: /Date of entry/

      assert_empty sent(calls, :record_advance_directive)
    end
  end

  test "S-REG-17.3 RPMS's refusal of the same type on the same date shows, with the form kept" do
    sign_in
    refusal = { success: false, error: :invalid, message: "an advance directive of this type is already on file for that date" }
    with_profile(advance_directives: ->(*) { [ LIVING_WILL ] }, record_advance_directive: ->(*, **) { refusal }) do
      post "#{BASE}/advance_directives",
           params: { advance_directive: { entered_on: "2026-11-02", directive: "Y", type_ien: "34" } }
    end
    assert_response :unprocessable_content
    assert_select "#advance-directives-alert", text: /already on file for that date/
    assert_select "#advance_directive_type_ien option[selected][value='34']"
  end

  test "S-REG-17.6 an entry is changed in place, and the field its answer does not keep is dropped" do
    sign_in
    with_profile(advance_directives: ->(*) { [ NONE ] }, change_advance_directive: ->(*, **) { { success: true } }) do |calls|
      get "#{BASE}/advance_directives/4/edit"
      assert_select "#advance_directive_reason[value='PATIENT HAS NONE']"

      post "#{BASE}/advance_directives/4",
           params: { advance_directive: { entered_on: "2026-11-09", directive: "Y", type_ien: "35", reason: "PATIENT HAS NONE" } }

      assert_redirected_to "#{BASE}/advance_directives"
      _name, args, kwargs = sent(calls, :change_advance_directive).sole
      assert_equal [ DFN, 4 ], args
      assert_equal({ directive: true, type: 35, reason: nil, entered_on: Date.new(2026, 11, 9) }, kwargs)
    end
  end

  test "S-REG-17.5 an entry entered in error is removed" do
    sign_in
    with_profile(advance_directives: ->(*) { [ LIVING_WILL ] }, remove_advance_directive: ->(*) { { success: true } }) do |calls|
      get "#{BASE}/advance_directives"
      assert_select "#advance-directives tr[data-advance-directive='3']", text: /LIVING WILL/

      post "#{BASE}/advance_directives/3/remove"

      assert_redirected_to "#{BASE}/advance_directives"
      assert_equal [ DFN, 3 ], sent(calls, :remove_advance_directive).sole[1]
    end
  end

  test "RPMS not answering a save is said plainly, not as saved" do
    sign_in
    with_profile(record_advance_directive: ->(*, **) { nil }) do
      post "#{BASE}/advance_directives",
           params: { advance_directive: { entered_on: "2026-11-09", directive: "N", reason: "PATIENT HAS NONE" } }
    end
    assert_response :service_unavailable
    assert_select "#advance-directives-alert", text: /did not say whether/
  end

  test "a user who may read the registration but not change it files nothing" do
    sign_in("")
    with_profile do |calls|
      post "#{BASE}/advance_directives",
           params: { advance_directive: { entered_on: "2026-11-09", directive: "N", reason: "PATIENT HAS NONE" } }
      post "#{BASE}/advance_directives/3/remove"

      assert_empty sent(calls, :record_advance_directive)
      assert_empty sent(calls, :remove_advance_directive)
    end
  end
end
