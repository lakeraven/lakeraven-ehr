# frozen_string_literal: true

require "active_job/test_helper"
require_relative "../support/enrollment_fhir"

World(EnrollmentFhirTestHelpers)
World(ActiveJob::TestHelper)
World(ActiveSupport::Testing::TimeHelpers)

Before("@enrollment") do
  @enrollment_transport = RecordingFakeEnrollmentHttpTransport.new
  @enrollment_sleep_log = []
  @enrollment_cache = ActiveSupport::Cache.lookup_store(:memory_store)
  @enrollment_job_adapter = ActiveJob::Base.queue_adapter
  ActiveJob::Base.queue_adapter = :test
  clear_enqueued_jobs
end

After("@enrollment") do
  ActiveJob::Base.queue_adapter = @enrollment_job_adapter if defined?(@enrollment_job_adapter)
end

Given("the enrollment FHIR service host is {string}") do |_host|
  @enrollment_base_url = EnrollmentFhirTestHelpers::ENROLLMENT_BASE_URL
end

Given("a synthetic patient with DFN {string} named {string}") do |dfn, name|
  @enrollment_patient_dfn = dfn
  @enrollment_patient_name = name
  assert_equal EnrollmentFhirTestHelpers::SYNTHETIC_PATIENT_DFN, dfn
  assert_equal EnrollmentFhirTestHelpers::SYNTHETIC_PATIENT_NAME, name
end

Given("the enrollment service accepts Medicare eligibility checks for patient {string}") do |dfn|
  stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body(patient_dfn: dfn), transport: @enrollment_transport)
  @enrollment_client, @enrollment_cache, @enrollment_sleep_log, @enrollment_transport = build_enrollment_client(
    http: @enrollment_transport,
    cache: @enrollment_cache,
    sleep_log: @enrollment_sleep_log
  )
end

Given("the enrollment service is unavailable for eligibility checks") do
  stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
  @enrollment_client, @enrollment_cache, @enrollment_sleep_log, @enrollment_transport = build_enrollment_client(
    http: @enrollment_transport,
    cache: @enrollment_cache,
    sleep_log: @enrollment_sleep_log
  )
end

Given("the enrollment service lists active Medicaid coverage for patient {string}") do |_dfn|
  stub_enrollment_coverage_search(coverages: [ sample_medicaid_coverage_resource ], transport: @enrollment_transport)
  @enrollment_client, @enrollment_cache, @enrollment_sleep_log, @enrollment_transport = build_enrollment_client(
    http: @enrollment_transport,
    cache: @enrollment_cache,
    sleep_log: @enrollment_sleep_log
  )
end

Given("I checked Medicare Part B eligibility for patient {string} one hour ago") do |dfn|
  step "the enrollment service accepts Medicare eligibility checks for patient \"#{dfn}\""
  travel_to Time.zone.local(2026, 3, 15, 9, 0, 0) do
    request = build_enrollment_request(
      patient_dfn: dfn,
      coverage_type: "medicare_b",
      service_date: Date.new(2026, 3, 15)
    )
    @enrollment_client.check_eligibility(request)
  end
end

When("I check Medicare Part B eligibility for patient {string} on {string}") do |dfn, service_date|
  @enrollment_request = build_enrollment_request(
    patient_dfn: dfn,
    coverage_type: "medicare_b",
    service_date: Date.parse(service_date)
  )
  @enrollment_response =
    travel_to Time.zone.local(2026, 3, 15, 10, 0, 0) do
      @enrollment_client.check_eligibility(@enrollment_request)
    end
end

When("I check Medicare Part B eligibility for patient {string} again on {string}") do |dfn, service_date|
  step "I check Medicare Part B eligibility for patient \"#{dfn}\" on \"#{service_date}\""
end

When("I fetch Medicaid coverage from enrollment for patient {string}") do |dfn|
  @enrollment_coverages = @enrollment_client.coverage_for(patient_dfn: dfn, coverage_type: "medicaid")
end

Then("the eligibility outcome should be enrolled") do
  assert @enrollment_response.enrolled?, "expected enrolled, got #{@enrollment_response.status}"
end

Then("the eligibility outcome should be pending") do
  assert @enrollment_response.pending?, "expected pending (checking), got #{@enrollment_response.status}"
  refute @enrollment_response.enrolled?
  refute @enrollment_response.not_enrolled?
end

Then("an enrollment eligibility retry job should be enqueued for that request") do
  assert_enqueued_with(job: Lakeraven::EHR::EnrollmentEligibilityRetryJob)
end

Then("the enrollment service should have received one CoverageEligibilityRequest") do
  assert_equal 1, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
end

Then("the enrollment service should have been asked three times") do
  assert_equal 3, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
end

Then("I should receive a FHIR Coverage with plan name {string}") do |plan_name|
  assert_equal 1, @enrollment_coverages.length
  assert_equal plan_name, @enrollment_coverages.first.dig("class", 0, "name")
end

Then("the Coverage payor should be {string}") do |payor|
  assert_equal payor, @enrollment_coverages.first.dig("payor", 0, "display")
end
