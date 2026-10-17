# frozen_string_literal: true

require_relative "../../test/support/patient_banner_test_helper"

module PatientBannerStepHelpers
  include PatientBannerTestHelper

  def patient_dfn_for_name(name)
    case name
    when "Anderson,Alice" then "1"
    when "DEMOPATIENT,MARA" then "3"
    else
      raise ArgumentError, "Unknown synthetic patient #{name.inspect}"
    end
  end

  def display_name_for(name)
    case name
    when "Anderson,Alice" then "Alice Anderson"
    when "DEMOPATIENT,MARA" then "MARA DEMOPATIENT"
    else
      name
    end
  end

  def parse_last_response!
    @last_response = last_response
  end
end
World(PatientBannerStepHelpers)

Before("@patient_banner") do
  enable_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
  @demo_original_client = nil
  @forgery_was = nil
end

After("@patient_banner") do
  restore_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
  if @demo_original_client
    RpmsRpc.configure { |c| c.client = @demo_original_client }
    @demo_original_client = nil
  end
end

Given("demo clinical seeds are loaded") do
  with_demo_clinical_seeds { nil }
end

Given("patient {string} is the active patient context") do |name|
  sign_in_clinician! unless @clinician_token
  @dfn = patient_dfn_for_name(name)
  @patient_display_name = display_name_for(name)
  open_patient_context!(@dfn)
  parse_last_response!
end

Given("the active patient has no recorded allergies in the chart source") do
  # Patient 3 is seeded with an empty allergy list in LakeravenDemoSeeds.
end

Given("the clinician is signed in with no patient in context") do
  sign_in_clinician!
  parse_last_response!
end

Given("the clinician is not signed in") do
  @clinician_token = nil
end

When("the clinician navigates to the dashboard") do
  get "#{PatientBannerTestHelper::MOUNT}/dashboard"
  parse_last_response!
end

When("the clinician navigates to the screenings index for that patient") do
  get "#{PatientBannerTestHelper::MOUNT}/patients/#{@dfn}/screenings"
  parse_last_response!
end

When("the clinician navigates to the HTML chart for that patient") do
  setup_chart_bearer! unless @chart_headers
  get "#{PatientBannerTestHelper::MOUNT}/patients/#{@dfn}", headers: @chart_headers
  parse_last_response!
end

When("the clinician visits the login page") do
  get "#{PatientBannerTestHelper::MOUNT}/login"
  parse_last_response!
end

When("the clinician activates {string}") do |label|
  assert_equal "Clear patient context", label
  get "#{PatientBannerTestHelper::MOUNT}/dashboard"
  submit_clear_patient_context!
  parse_last_response!
end

Then("the patient banner shows name, MRN, DOB, age, and sex") do
  assert_equal 200, @last_response.status
  assert_banner_demographics!(
    name: @patient_display_name,
    mrn: @dfn,
    dob: @dfn == "1" ? "May 15, 1980" : "Jun 30, 1997",
    age: @dfn == "1" ? "46" : "29",
    sex: "Female"
  )
end

Then("the patient banner remains visible when the page scrolls") do
  assert_banner_sticky_stylesheet!
end

Then("the banner allergies field displays {string}") do |text|
  field = allergies_field_node
  assert field, "Expected allergies field inside #patient-banner"
  assert_includes field.text, text
end

Then("the banner allergies field has state {string}") do |state|
  assert_equal state, allergies_field_node["data-allergies-state"]
end

Then("the allergies field is not hidden") do
  field = allergies_field_node
  assert field, "Expected allergies field"
  refute field["hidden"]
  refute_includes field["class"].to_s, "hidden"
  refute_equal "none", field["style"].to_s[/display:\s*(\w+)/, 1]
end

Then("no patient is in context") do
  get "#{PatientBannerTestHelper::MOUNT}/patients/#{@dfn}/screenings"
  assert_equal 403, last_response.status,
               "Expected screenings to require opening the record after clearing context"
end

Then("the banner shows the empty state directing to chart search") do
  assert_empty_banner!
end

Then("the banner shows {string} with a link to chart search") do |text|
  banner = assert_patient_banner!
  assert_includes banner.text, text
  link = banner.css("a").find { |a| a.text.match?(/chart search/i) }
  assert link, "Expected chart search link"
end

Then("no clinical screen renders patient data") do
  body = html_response_body
  refute_includes body, "Alice Anderson"
  refute_includes body, "111-11-1111"
end

Then("no patient data is rendered") do
  assert_nil patient_banner_node
  body = html_response_body
  refute_includes body, "Alice Anderson"
  refute_includes body, "No patient selected"
end
