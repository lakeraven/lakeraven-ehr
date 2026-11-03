# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-10 (languages). RpmsRpc::PatientProfile reads and files through AG's
# windows and runs AG's own field checks; these tests stand in for it at the
# gem boundary and check what the screens send and show.
class RegistrationLanguagesTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  # -- S-REG-10 ---------------------------------------------------------------

  def save_languages(**entry)
    post "#{BASE}/languages", params: { languages: entry }
  end

  test "S-REG-10.1 the languages are sent to RPMS as one new entry" do
    sign_in
    with_profile(record_languages: ->(*, **) { { success: true, dfn: DFN, entry: 3 } }) do |calls|
      save_languages(primary_ien: SPANISH, interpreter: "Y", proficiency: "NW", preferred_ien: SPANISH, others: [ "", ENGLISH ])

      assert_redirected_to "#{BASE}#languages-section"
      call = sent(calls, :record_languages).sole
      assert_equal [ DFN ], call[1]
      assert_equal({ primary: SPANISH, preferred: SPANISH, proficiency: "NW", interpreter: "Y", others: [ ENGLISH ], english_ien: ENGLISH }, call[2])
    end
  end

  test "S-REG-10.2 English without a proficiency, or with not at all, is refused" do
    sign_in
    with_profile do |calls|
      save_languages(primary_ien: ENGLISH, preferred_ien: ENGLISH)
      assert_response :unprocessable_content
      assert_select "#languages-errors", text: /needed when the patient speaks English/

      save_languages(primary_ien: SPANISH, interpreter: "N", others: [ ENGLISH ], proficiency: "NA")
      assert_response :unprocessable_content
      assert_select "#languages-errors", text: /Not at all/
      assert_empty sent(calls, :record_languages)
    end
  end

  test "S-REG-10.3 a primary language other than English asks whether an interpreter is needed" do
    sign_in
    with_profile do |calls|
      save_languages(primary_ien: SPANISH, preferred_ien: SPANISH)

      assert_response :unprocessable_content
      assert_select "#languages-errors", text: /Interpreter must be answered/
      assert_empty sent(calls, :record_languages)
    end
  end

  test "S-REG-10.4 an other language that is the primary, or listed twice, is refused" do
    sign_in
    with_profile do |calls|
      save_languages(primary_ien: SPANISH, interpreter: "Y", others: [ SPANISH ])
      assert_select "#languages-errors", text: /cannot include the primary language/

      save_languages(primary_ien: SPANISH, interpreter: "Y", proficiency: "W", others: [ ENGLISH, ENGLISH ])
      assert_select "#languages-errors", text: /cannot list a language twice/
      assert_empty sent(calls, :record_languages)
    end
  end

  test "S-REG-10.5 a preferred language not spoken otherwise warns, and saves when the clerk saves again" do
    sign_in
    with_profile(record_languages: ->(*, **) { { success: true, dfn: DFN, entry: 4 } }) do |calls|
      save_languages(primary_ien: ENGLISH, proficiency: "VW", preferred_ien: SPANISH)
      assert_response :unprocessable_content
      assert_select "#preferred-warning", text: /not the primary language/
      assert_select "input[name='languages[preferred_confirmed]'][value='1']"
      assert_empty sent(calls, :record_languages)

      save_languages(primary_ien: ENGLISH, proficiency: "VW", preferred_ien: SPANISH, preferred_confirmed: "1")
      assert_redirected_to "#{BASE}#languages-section"
      assert_equal SPANISH, sent(calls, :record_languages).sole[2][:preferred]
    end
  end

  test "S-REG-10.1 the patient's page shows the latest languages entry" do
    sign_in
    languages = { date: "NOV 3,2026", primary: { ien: SPANISH, name: "SPANISH" }, preferred: { ien: SPANISH, name: "SPANISH" },
                  interpreter: "Y", proficiency: "NW", others: [ { ien: ENGLISH, name: "ENGLISH" } ] }
    with_profile(languages: ->(*) { languages }) do
      get BASE
    end

    assert_select "#languages-section [data-field='primary']", text: "Spanish"
    assert_select "#languages-section [data-field='others']", text: "English"
    assert_select "#languages-section [data-field='interpreter']", text: "Yes"
  end
end
