# frozen_string_literal: true

require "nokogiri"
require_relative "../../test/support/patient_banner_test_helper"

# Find a diagnosis (features/terminology/diagnosis_search.feature) and the
# vaccines due (features/immunization/vaccines_due.feature): pages that show
# what RPMS's terminology and immunization packages answer.
module ExternalServiceReadSteps
  include PatientBannerTestHelper

  def page_doc = Nokogiri::HTML(html_response_body)
end
World(ExternalServiceReadSteps)

# The @live scenarios assert what RPMS's terminology and immunization
# packages answer. The stand-in holds no BSTS copy and no forecast, and answering
# one would be our guess at RPMS, so on the stand-in they are not run: run them
# with cucumber --profile live against the pinned image.
Before("(@diagnosis_search or @vaccines_due) and @live") do
  skip_this_scenario("not run: needs RPMS (cucumber --profile live)") unless LIVE_RPMS
end

Before("@diagnosis_search or @vaccines_due") { enable_forgery_protection! }
After("@diagnosis_search or @vaccines_due") do
  restore_forgery_protection!
  teardown_oauth!
end

Given("the provider is signed in") do
  sign_in_clinician!
end

# One process holds one broker identity: the shared session signs on as the
# front desk clerk's published demo pair, whose menu has no BSTSRPC, and the
# run's persona signs back on after (authentication_steps.rb).
Given("the front desk clerk is signed on to RPMS") do
  @signed_on_as_scenario_user = true
  result = Lakeraven::EHR::AuthenticationService.new.authenticate(access_code: "PREG123", verify_code: "PREG123!!")
  assert result.success?, "the front desk clerk's published pair did not sign on: #{result.error}"
end

When("the provider searches for the diagnosis {string}") do |term|
  get "#{PatientBannerTestHelper::MOUNT}/diagnosis_search", { q: term }
end

Then("RPMS offers the SNOMED CT concept {string} with ICD-10-CM {string}") do |concept_id, icd|
  assert_equal 200, current_response.status, html_response_body[0, 500]
  row = page_doc.at_css("#diagnosis-search-results tr[data-concept-id='#{concept_id}']")
  refute_nil row, "no row for SNOMED CT #{concept_id} in: #{page_doc.css('#diagnosis-search-results td[data-snomed]').map(&:text)}"
  assert_includes row.at_css("td[data-icd]").text.split(/,\s*/), icd
end

Then("the page offers words that start with {string}") do |prefix|
  words = page_doc.css("#diagnosis-search-words a").map(&:text)
  refute_empty words, "no words offered"
  words.each { |word| assert word.downcase.start_with?(prefix), "#{word.inspect} does not start with #{prefix.inspect}" }
end

When("the provider opens the SNOMED CT concept {string}") do |concept_id|
  link = page_doc.at_css("#diagnosis-search-results tr[data-concept-id='#{concept_id}'] th a")
  refute_nil link, "no link to concept #{concept_id}"
  get link["href"]
end

Then("the concept's fully specified name is {string}") do |fsn|
  assert_equal 200, current_response.status, html_response_body[0, 500]
  assert_equal fsn, page_doc.at_css("#diagnosis-concept dd[data-fsn]")&.text&.strip
end

Then("the concept's ICD-10-CM code is {string}") do |icd|
  assert_includes page_doc.at_css("#diagnosis-concept dd[data-icd]").text.split(/,\s*/), icd
end

Then("the page says no SNOMED CT concept in RPMS matches {string}") do |term|
  assert_equal 200, current_response.status
  assert_includes page_doc.at_css("#diagnosis-search-none")&.text.to_s, "No SNOMED CT concept in RPMS matches “#{term}”."
end

Then("no concept is offered") do
  assert_nil page_doc.at_css("#diagnosis-search-results")
end

Then("the page says RPMS refused the request") do
  assert_equal 403, current_response.status, html_response_body[0, 500]
  assert_includes page_doc.at_css("#rpms-unavailable")&.text.to_s, "RPMS refused this request"
end

Then("the page asks for a term without | or ^") do
  assert_equal 422, current_response.status
  assert_includes page_doc.at_css("#diagnosis-search-refused")&.text.to_s, "without | or ^"
end

Given("the provider has opened the record of patient {string} with immunization read") do |dfn|
  sign_in_clinician!(scopes: "#{PatientBannerTestHelper::BANNER_SCOPES} user/Immunization.read")
  @dfn = dfn
  open_patient_context!(dfn)
end

When("the provider opens the patient's vaccines due") do
  get "#{PatientBannerTestHelper::MOUNT}/patients/#{@dfn}/immunizations/due"
end

Then("the page says RPMS did not produce an immunization forecast") do
  assert_equal 200, current_response.status, html_response_body[0, 800]
  assert_includes page_doc.at_css("#immunization-forecast-unavailable")&.text.to_s,
                  "RPMS did not produce an immunization forecast for this patient"
end

Then("the page quotes the Immunization package's reason {string}") do |reason|
  assert_includes page_doc.at_css("#immunization-forecast-unavailable").text, "“#{reason}”"
end

Then("no vaccine is listed as due") do
  assert_nil page_doc.at_css("#immunization-forecast")
  assert_nil page_doc.at_css("#immunization-forecast-none-due"), "a forecast that was not made must not read as none due"
end
