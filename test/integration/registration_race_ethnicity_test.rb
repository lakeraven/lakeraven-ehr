# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-20.2 to 20.4 (race and ethnicity). RpmsRpc::Registration reads
# and files RACE INFORMATION and ETHNICITY INFORMATION (PATIENT 2.02, 2.06)
# with their methods of collection; these tests stand in for it at the gem
# boundary and check what the screens send and show.
class RegistrationRaceEthnicityTest < ActionDispatch::IntegrationTest
  include PatientProfileStubs

  CHOICES = {
    races: [ { ien: 2, name: "AMERICAN INDIAN OR ALASKA NATIVE" }, { ien: 11, name: "DECLINED TO ANSWER" },
             { ien: 14, name: "WHITE" } ],
    ethnicities: [ { ien: 1, name: "HISPANIC OR LATINO" }, { ien: 2, name: "NOT HISPANIC OR LATINO" } ],
    methods: [ { ien: 3, name: "OBSERVER" }, { ien: 2, name: "PROXY" }, { ien: 1, name: "SELF IDENTIFICATION" } ]
  }.freeze
  ON_FILE = { races: [ { ien: 2, name: "AMERICAN INDIAN OR ALASKA NATIVE", method: 1, method_name: "SELF IDENTIFICATION" } ],
              ethnicities: [] }.freeze

  def answers(**more)
    { race_ethnicity: ->(*) { ON_FILE }, race_ethnicity_choices: ->(*) { CHOICES } }.merge(more)
  end

  def form(races:, ethnicities:)
    to_rows = ->(chosen) { chosen.to_h { |code, method| [ code.to_s, { chosen: "1", method: method.to_s } ] } }
    { race_ethnicity: { races: to_rows.call(races), ethnicities: to_rows.call(ethnicities) } }
  end

  test "S-REG-20.2 the patient's page shows each race and ethnicity with how it was collected" do
    sign_in
    with_profile(**answers) do
      get BASE
    end

    assert_select "#race-ethnicity-section [data-field='races']", text: /American Indian Or Alaska Native\s*\(self identification\)/
    assert_select "#race-ethnicity-section [data-field='ethnicities']", text: /Not recorded/
    assert_select "a#edit-race-ethnicity[href=?]", "#{BASE}/race_ethnicity/edit"
  end

  test "S-REG-20.2 the form ticks what is on file and offers each race with its method" do
    sign_in
    with_profile(**answers) do
      get "#{BASE}/race_ethnicity/edit"
    end

    assert_response :success
    assert_select "#races-2-chosen[checked]"
    assert_select "#races-14-chosen:not([checked])"
    assert_select "#races-14-method option[selected]", text: "Self identification"
    assert_select "#ethnicities-fieldset input[type=checkbox]", count: 2
  end

  test "S-REG-20.2 the races and ethnicities ticked are sent to RPMS with their methods" do
    sign_in
    with_profile(**answers(set_race_ethnicity: ->(*, **) { { success: true } })) do |calls|
      post "#{BASE}/race_ethnicity", params: form(races: { 2 => 1, 14 => 2 }, ethnicities: { 2 => 1 })

      assert_redirected_to "#{BASE}#race-ethnicity-section"
      sent_call = sent(calls, :set_race_ethnicity).sole
      assert_equal [ DFN ], sent_call[1]
      assert_equal({ races: [ { code: 2, method: 1 }, { code: 14, method: 2 } ], ethnicities: [ { code: 2, method: 1 } ] }, sent_call[2])
    end
  end

  test "S-REG-20.3 no race or no ethnicity is refused, naming which, before RPMS is asked" do
    sign_in
    with_profile(**answers) do |calls|
      post "#{BASE}/race_ethnicity", params: form(races: { 2 => 1 }, ethnicities: {})

      assert_response :unprocessable_content
      assert_select "#ethnicities-error", text: /Choose at least one ethnicity/
      assert_select "#races-error", count: 0
      assert_empty sent(calls, :set_race_ethnicity)
    end
  end

  test "S-REG-20.4 declined beside another race shows RPMS's reason and keeps the form" do
    sign_in
    refusal = { success: false, error: :invalid,
                message: "declined to answer or unknown by patient cannot be recorded with another race" }
    with_profile(**answers(set_race_ethnicity: ->(*, **) { refusal })) do
      post "#{BASE}/race_ethnicity", params: form(races: { 11 => 1, 14 => 1 }, ethnicities: { 2 => 1 })

      assert_response :unprocessable_content
      assert_select "#race-ethnicity-alert", text: /cannot be recorded with another race/
      assert_select "#races-11-chosen[checked]"
    end
  end

  test "S-REG-20.2 when RPMS does not answer, the clerk is told to check before saving again" do
    sign_in
    with_profile(**answers(set_race_ethnicity: ->(*, **) { nil })) do
      post "#{BASE}/race_ethnicity", params: form(races: { 2 => 1 }, ethnicities: { 2 => 1 })

      assert_response :service_unavailable
      assert_select "#race-ethnicity-alert", text: /did not say whether/
    end
  end
end
