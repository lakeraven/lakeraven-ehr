# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-12.1 (preferred name). RpmsRpc::Registration reads and files
# PREFERRED NAME (IHS PATIENT 9000001 field 9001); these tests stand in for it
# at the gem boundary and check what the screens send and show.
class RegistrationPreferredNameTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  test "S-REG-12.1 the patient's page shows the preferred name beside who the patient is" do
    sign_in
    with_profile(preferred_name: ->(*) { "DEE" }) do
      get BASE
    end

    assert_select "#preferred-name-section [data-field='preferred_name']", text: "DEE"
    assert_select "#registration [data-field='preferred_name']", text: "DEE"
    assert_select "#edit-preferred-name"
  end

  test "S-REG-12.1 with none on file the page says so and the summary leaves it out" do
    sign_in
    with_profile do
      get BASE
    end

    assert_select "#preferred-name-section [data-field='preferred_name']", text: /None on file/
    assert_select "#registration [data-field='preferred_name']", count: 0
  end

  test "S-REG-12.1 a preferred name is saved through RPMS in capitals" do
    sign_in
    with_profile(set_preferred_name: ->(*) { { success: true, changed: true } }) do |calls|
      post "#{BASE}/preferred_name", params: { preferred_name: { name: "  dee  ann " } }

      assert_redirected_to "#{BASE}#preferred-name-section"
      assert_equal [ DFN, "DEE ANN" ], sent(calls, :set_preferred_name).sole[1]
    end
  end

  test "S-REG-12.1 a blank preferred name clears it" do
    sign_in
    with_profile(set_preferred_name: ->(*) { { success: true, changed: true } }) do |calls|
      post "#{BASE}/preferred_name", params: { preferred_name: { name: "" } }

      assert_equal [ DFN, "" ], sent(calls, :set_preferred_name).sole[1]
      assert_equal "Preferred name cleared.", flash[:notice]
    end
  end

  test "S-REG-12.1 a preferred name over 30 characters is refused before RPMS is asked" do
    sign_in
    with_profile do |calls|
      post "#{BASE}/preferred_name", params: { preferred_name: { name: "A" * 31 } }

      assert_response :unprocessable_content
      assert_select "#preferred-name-errors"
      assert_empty sent(calls, :set_preferred_name)
    end
  end

  test "S-REG-12.1 RPMS's refusal is shown in its words" do
    sign_in
    with_profile(set_preferred_name: ->(*) { { success: false, error: :lock_failed, message: "Held by DEMO,USER." } }) do
      post "#{BASE}/preferred_name", params: { preferred_name: { name: "DEE" } }

      assert_response :unprocessable_content
      assert_select "#preferred-name-alert", text: /Held by DEMO,USER/
    end
  end

  test "S-REG-12.1 an answer RPMS never gave is said to be unknown" do
    sign_in
    with_profile(set_preferred_name: ->(*) { raise RpmsRpc::Client::ConnectionError, "gone" }) do
      post "#{BASE}/preferred_name", params: { preferred_name: { name: "DEE" } }

      assert_response :service_unavailable
      assert_select "#preferred-name-alert", text: /did not say whether/
    end
  end

  test "S-REG-12.1 the edit form shows what is on file" do
    sign_in
    with_profile(preferred_name: ->(*) { "DEE" }) do
      get "#{BASE}/preferred_name/edit"
    end

    assert_select "#preferred_name_name[value='DEE'][maxlength='30']"
  end

  test "S-REG-12.1 a view-only registration user sees the preferred name but cannot change it" do
    sign_in("registration_view_only")
    with_profile(preferred_name: ->(*) { "DEE" }) do |calls|
      get BASE
      assert_select "#preferred-name-section [data-field='preferred_name']", text: "DEE"
      assert_select "#edit-preferred-name", count: 0

      post "#{BASE}/preferred_name", params: { preferred_name: { name: "OTHER" } }
      assert_response :forbidden
      assert_empty sent(calls, :set_preferred_name)
    end
  end
end
