# frozen_string_literal: true

require_relative "../../test/support/url_patient_context_test_helper"
require_relative "../../test/support/sensitive_patient_access_seeds"

# Steps for features/bprm_twin/sensitive_patient_access.feature (#613).
#
# RPMS is the mock, seeded with the wire reply lines of DG SENSITIVE RECORD
# ACCESS and DG SENSITIVE RECORD BULLETIN (SensitivePatientAccessSeeds), so
# the gem's own parser reads them. Synthetic patients: DFN 1 and DFN 3 of the
# baseline seeds. Sign-in, the CSRF token and the session read are the
# URL-patient-context helpers, already in the World.
module SensitivePatientAccessStepHelpers
  include UrlPatientContextTestHelper
  include SensitivePatientAccessSeeds

  DENIED_MESSAGE = "Access to your own record is not allowed."
  # What the baseline seeds hold for the synthetic patients (test/test_helper.rb).
  PATIENT_DETAILS = {
    1 => [ /\bAnderson\b/i, /\bAlice\b/i, /111-11-1111/, /111111111/, /1980/ ],
    3 => [ /\bDOE\b/i, /\bJANE\b/i, /555667777/, /555-66-7777/, /1990/ ]
  }.freeze

  def sensitive_context_path(dfn) = "#{MOUNT}/patients/#{dfn}/context"

  def sensitive_acknowledgement_form
    Nokogiri::HTML(last_response.body).css("form").find do |form|
      form["action"].to_s.match?(%r{/patients/\d+/context\z}) && form.at_css("input[name='acknowledge_sensitive']")
    end
  end
end

World(SensitivePatientAccessStepHelpers)

Before("@sensitive_patient_access") do
  enable_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
end

After("@sensitive_patient_access") do
  restore_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
end

Given("a clinician is signed in to open patient records") do
  sign_in_clinician!
end

Given("RPMS answers that patient {int} is not a sensitive record") do |dfn|
  seed_not_sensitive!(dfn)
end

Given("RPMS answers that patient {int} is a sensitive record the user must acknowledge") do |dfn|
  seed_sensitive_access!(dfn, 2, SensitivePatientAccessSeeds::WARNING_LINES)
end

Given("RPMS answers that patient {int} is a sensitive record the user may open without acknowledging") do |dfn|
  seed_sensitive_access!(dfn, 1, SensitivePatientAccessSeeds::WARNING_LINES)
end

Given("RPMS answers that access to patient {int} is denied") do |dfn|
  seed_sensitive_access!(dfn, 3, [ SensitivePatientAccessStepHelpers::DENIED_MESSAGE ])
end

Given("RPMS does not answer whether patient {int} is a sensitive record") do |dfn|
  clear_sensitive_access!(dfn)
end

Given("RPMS will write the security log entry and send the bulletin for patient {int}") do |dfn|
  seed_sensitive_bulletin!(dfn, true)
end

When("the clinician opens the record of patient {int}") do |dfn|
  post sensitive_context_path(dfn), { authenticity_token: csrf_token }
end

When("the clinician acknowledges the sensitive record warning") do
  form = sensitive_acknowledgement_form
  assert form, "expected the sensitive record warning's acknowledgement form"
  fields = form.css("input[name]").to_h { |input| [ input["name"], input["value"] ] }
  post form["action"], fields
end

Then("the sensitive record warning from RPMS is shown with a way to acknowledge it") do
  assert_equal 403, last_response.status, last_response.body[0, 300]
  SensitivePatientAccessSeeds::WARNING_LINES.each do |line|
    assert_includes last_response.body, ERB::Util.html_escape(line.strip), "RPMS warning line missing: #{line.inspect}"
  end
  form = sensitive_acknowledgement_form
  assert form, "expected a form that posts the acknowledgement back to the open"
  assert_equal "post", form["method"].to_s.downcase
  assert_equal "1", form.at_css("input[name='acknowledge_sensitive']")["value"]
end

Then("the warning shows no details of patient {int}") do |dfn|
  SensitivePatientAccessStepHelpers::PATIENT_DETAILS.fetch(dfn).each do |detail|
    refute_match detail, last_response.body, "the warning must not show patient details (#{detail.inspect})"
  end
end

Then("the record of patient {int} is open") do |dfn|
  assert last_response.redirect?, "expected the open to redirect, got #{last_response.status}"
  assert last_response.headers["Location"].to_s.end_with?(sensitive_context_path(dfn).delete_suffix("/context")),
         "expected a redirect to the chart of patient #{dfn}, got #{last_response.headers['Location']}"
  assert_equal dfn.to_s, session_open_patient_dfn
end

Then("no patient record is open") do
  assert_nil session_open_patient_dfn, "no record may be open in the session"
end

Then("the open is refused with RPMS's reason") do
  assert_equal 403, last_response.status, last_response.body[0, 300]
  assert_includes last_response.body, ERB::Util.html_escape(SensitivePatientAccessStepHelpers::DENIED_MESSAGE)
  assert_nil sensitive_acknowledgement_form, "a denied record offers no acknowledgement"
end

Then("the open is refused") do
  assert_includes [ 403, 503 ], last_response.status, "expected the open to be refused, got #{last_response.status}"
  assert_nil sensitive_acknowledgement_form, "nothing to acknowledge when RPMS gave no warning"
end

Then("RPMS was asked whether patient {int} is a sensitive record") do |dfn|
  calls = sensitive_access_calls
  assert_equal 1, calls.size, "expected one DG SENSITIVE RECORD ACCESS, got #{calls.size}"
  assert_equal dfn.to_s, calls.first[:params][0]
  assert_equal SensitivePatientAccessSeeds::OPTION, calls.first[:params][2]
end

Then("no sensitive record bulletin was sent") do
  assert_empty sensitive_bulletin_calls, "DG SENSITIVE RECORD BULLETIN must not be sent"
end

Then("RPMS was asked to write the security log entry and send the bulletin for patient {int}") do |dfn|
  assert_equal 2, sensitive_access_calls.size, "the check runs on the first open and again on the acknowledgement"
  expected = [ [ dfn.to_s, SensitivePatientAccessSeeds::OPTION, SensitivePatientAccessSeeds::LOG_AND_SEND ] ]
  assert_equal expected, sensitive_bulletin_calls.map { |call| call[:params].to_a }
end
