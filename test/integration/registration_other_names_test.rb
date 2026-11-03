# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-12 (other names). RpmsRpc::PatientProfile reads and files through AG's
# windows and runs AG's own field checks; these tests stand in for it at the
# gem boundary and check what the screens send and show.
class RegistrationOtherNamesTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  # -- S-REG-12 ---------------------------------------------------------------

  test "S-REG-12.2 the patient's page lists the other names" do
    sign_in
    with_profile(aliases: ->(*) { [ { ien: 1, name: "OLDNAME,ROBIN" } ] }) do
      get BASE
    end

    assert_select "#other-names-list li[data-other-name='1']", text: "OLDNAME,ROBIN"
    assert_select "#edit-other-names"
  end

  test "S-REG-12.2 an other name is added through RPMS" do
    sign_in
    with_profile(add_alias: ->(*) { { success: true, ien: 3 } }) do |calls|
      post "#{BASE}/other_names", params: { other_name: { name: "oldname,robin" } }

      assert_redirected_to "#{BASE}/other_names"
      assert_equal [ DFN, "OLDNAME,ROBIN" ], sent(calls, :add_alias).sole[1]
    end
  end

  test "S-REG-12.3 an other name out of format or length is refused and names the format" do
    sign_in
    with_profile do |calls|
      post "#{BASE}/other_names", params: { other_name: { name: "ROBIN OLDNAME" } }
      assert_response :unprocessable_content
      assert_select "#other-name-errors", text: /LAST,FIRST MIDDLE/

      post "#{BASE}/other_names", params: { other_name: { name: "#{'A' * 20},#{'B' * 20}" } }
      assert_response :unprocessable_content
      assert_empty sent(calls, :add_alias)
    end
  end

  test "S-REG-12.4 an other name entered in error is removed by its entry" do
    sign_in
    with_profile(aliases: ->(*) { [ { ien: 1, name: "OLDNAME,ROBIN" }, { ien: 2, name: "SECOND,ROBIN" } ] },
                 remove_alias: ->(*) { { success: true, ien: 2 } }) do |calls|
      get "#{BASE}/other_names"
      assert_select "#other-names tr[data-other-name='2']", text: /SECOND,ROBIN/

      post "#{BASE}/other_names/2/remove"
      assert_redirected_to "#{BASE}/other_names"
      assert_equal [ DFN, 2 ], sent(calls, :remove_alias).sole[1]
    end
  end

  test "an answer RPMS never gave is said to be unknown, not refused" do
    sign_in
    with_profile(add_alias: ->(*) { raise RpmsRpc::Client::ConnectionError, "gone" }) do
      post "#{BASE}/other_names", params: { other_name: { name: "OLDNAME,ROBIN" } }

      assert_response :service_unavailable
      assert_select "#other-names-alert", text: /did not say whether/
    end
  end
end
