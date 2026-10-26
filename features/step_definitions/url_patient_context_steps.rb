# frozen_string_literal: true

require_relative "../../test/support/url_patient_context_test_helper"
require "active_support/testing/time_helpers"

module UrlPatientContextStepHelpers
  include UrlPatientContextTestHelper
  include ActiveSupport::Testing::TimeHelpers
end

World(UrlPatientContextStepHelpers)

Before("@url_patient_context") do
  enable_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
  travel_to Time.zone.local(2026, 10, 17, 12, 0, 0)
end

After("@url_patient_context") do
  travel_back
  restore_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
  if @demo_original_client
    RpmsRpc.configure { |c| c.client = @demo_original_client }
    @demo_original_client = nil
  end
  @patient_repository_restore&.call
  @patient_repository_restore = nil
end

Given("the clinician is signed in for URL patient context") do
  sign_in_clinician! unless @clinician_token
end

Given("the clinician has the HTML chart for patient {int} open") do |dfn|
  @dfn = dfn.to_s
  @patient_display_name = dfn == 1 ? "Alice Anderson" : "Patient #{dfn}"
  get_chart_for_dfn!(@dfn)
  assert_equal 200, last_response.status, last_response.body[0, 500]
end

When("the browser reloads the chart page") do
  get_chart_for_dfn!(@dfn)
end

Then("patient {int} is the active patient context") do |dfn|
  assert_chart_derives_patient_from_url!(dfn)
end

Then("the banner reflects patient {int}") do |dfn|
  assert_equal 200, last_response.status
  case dfn
  when 1
    assert_banner_demographics!(
      name: "Alice Anderson",
      mrn: "1",
      dob: "May 15, 1980",
      age: "46",
      sex: "Female"
    )
  else
    flunk "Add banner expectations for synthetic patient #{dfn}"
  end
end

Given("the clinician has patient {int} open in session") do |dfn|
  @dfn = dfn.to_s
  open_patient_context!(dfn)
  assert_equal dfn.to_s, session_open_patient_dfn,
               "patient context is opened only via audited POST /patients/:dfn/context"
end

When("the clinician follows a chart link for an invalid patient identifier") do
  @invalid_chart_segment = "not-a-valid-dfn"
  get chart_path_for(@invalid_chart_segment)
  @last_response = last_response
end

Then("the patient context is cleared") do
  assert_session_patient_context_cleared!
end

Then("the clinician is redirected to patient search with an explanatory message") do
  assert_not_format_error_response!
  assert_invalid_identifier_redirect_flash_and_no_scaffold!
end

Then("no partial patient data is rendered") do
  assert_no_chart_patient_data!
end

Given("the chart patient lookup fails in the backend") do
  @patient_repository_restore = StubHelpers.send(
    :singleton_method_restore,
    Lakeraven::EHR::PatientRepository,
    :find
  )
  Lakeraven::EHR::PatientRepository.define_singleton_method(:find) do |*_args, **_kwargs|
    raise StandardError, "rpms unavailable"
  end
end

When("the clinician opens the HTML chart for patient {int}") do |dfn|
  @dfn = dfn.to_s
  without_show_exceptions do
    get_chart_for_dfn!(@dfn)
  end
  @chart_response = last_response
  @last_response = last_response
end

Then("the failure is shown as an error state, not an empty chart") do
  assert_chart_load_error_state!
end
