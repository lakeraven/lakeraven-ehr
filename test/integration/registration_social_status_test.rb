# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-11 and S-REG-31.3 (migrant, homeless and internet answers).
# RpmsRpc::PatientProfile files through AG's Other Patient window; these tests
# stand in for it at the gem boundary and check what the screens send and show.
class RegistrationSocialStatusTest < ActionDispatch::IntegrationTest
  include BrowserFormHelper
  include PatientProfileStubs

  def save(**entry)
    post "#{BASE}/social_status", params: { social_status: entry }
  end

  test "S-REG-11.1 and 11.2 a yes is sent with its type" do
    sign_in
    with_profile(record_social_status: ->(*, **) { { success: true, dfn: DFN } }) do |calls|
      save(migrant: "Y", migrant_type: "S", homeless: "Y", homeless_type: "T")

      assert_redirected_to "#{BASE}#social-status-section"
      call = sent(calls, :record_social_status).sole
      assert_equal [ DFN ], call[1]
      assert_equal({ migrant: "Y", migrant_type: "S", homeless: "Y", homeless_type: "T" }, call[2])
    end
  end

  test "S-REG-11.3 a yes without its type is refused and asks for the type" do
    sign_in
    with_profile do |calls|
      save(migrant: "Y", homeless: "Y")

      assert_response :unprocessable_content
      assert_select "#social-status-errors", text: /needed for a migrant worker/
      assert_select "#social-status-errors", text: /needed for a homeless patient/
      assert_empty sent(calls, :record_social_status)
    end
  end

  test "S-REG-11.4 a no is sent without a type, even when one was picked" do
    sign_in
    with_profile(record_social_status: ->(*, **) { { success: true, dfn: DFN } }) do |calls|
      save(homeless: "N", homeless_type: "S")

      assert_equal({ homeless: "N" }, sent(calls, :record_social_status).sole[2])
    end
  end

  test "S-REG-31.3 only the questions answered are sent" do
    sign_in
    with_profile(record_social_status: ->(*, **) { { success: true, dfn: DFN } }) do |calls|
      save(internet: "N")

      assert_equal({ internet: false }, sent(calls, :record_social_status).sole[2])
    end
  end

  test "no answer at all is refused before RPMS is asked" do
    sign_in
    with_profile do |calls|
      save(migrant: "")

      assert_response :unprocessable_content
      assert_select "#social-status-errors", text: /at least one question/
      assert_empty sent(calls, :record_social_status)
    end
  end

  test "RPMS's refusal is shown, and an unanswered write says the outcome is unknown" do
    sign_in
    with_profile(record_social_status: ->(*, **) { { success: false, error: :invalid, message: "AG refused it" } }) do
      save(internet: "Y")
      assert_response :unprocessable_content
      assert_select "#social-status-alert", text: /AG refused it/
    end
    with_profile(record_social_status: ->(*, **) { nil }) do
      save(internet: "Y")
      assert_response :service_unavailable
      assert_select "#social-status-alert", text: /did not say whether/
    end
  end

  test "the registration page shows the latest answers with their dates" do
    sign_in
    status = { migrant: { status: "Y", type: "M", date: "NOV 5,2026" }, homeless: { status: "N", type: nil, date: "NOV 5,2026" },
               internet: { access: false, date: "NOV 5,2026" } }
    with_profile(social_status: ->(*) { status }) do
      get BASE

      assert_select "#social-status-section [data-field='migrant']", text: /Yes, Migrant agricultural worker, NOV 5,2026/
      assert_select "#social-status-section [data-field='homeless']", text: /No, NOV 5,2026/
      assert_select "#social-status-section [data-field='internet']", text: /No, NOV 5,2026/
    end
  end

  test "a patient asked nothing shows Not asked, and the form starts blank" do
    sign_in
    with_profile do
      get BASE
      assert_select "#social-status-section [data-field='homeless']", text: /Not asked/

      get "#{BASE}/social_status/edit"
      assert_response :ok
      assert_select "#social-status-form input[type=radio][checked]", count: 0
    end
  end

  test "a user who may read the registration but not change it gets no link and no write" do
    sign_in("")
    with_profile do |calls|
      get BASE
      assert_select "#edit-social-status", count: 0

      save(internet: "Y")
      assert_empty sent(calls, :record_social_status)
    end
  end
end
