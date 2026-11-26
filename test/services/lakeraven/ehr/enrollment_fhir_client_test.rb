# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/enrollment_fhir_test_helpers"

module Lakeraven
  module EHR
    class EnrollmentFHIRClientTest < ActiveSupport::TestCase
      include EnrollmentFhirTestHelpers
      include ActiveJob::TestHelper
      include ActiveSupport::Testing::TimeHelpers

      RETRY_ENQUEUE_FAILED_LOG = "Enrollment eligibility retry could not be enqueued"

      setup do
        @enrollment_transport = RecordingFakeEnrollmentHttpTransport.new
        @request = build_enrollment_request
      end

      test "requires an https base_url" do
        error = assert_raises(ArgumentError) do
          Lakeraven::EHR::EnrollmentFHIRClient.new(base_url: "http://enrollment.example.test")
        end
        refute_includes error.message, SYNTHETIC_PATIENT_DFN
      end

      test "rejects a blank base_url" do
        assert_raises(ArgumentError) { Lakeraven::EHR::EnrollmentFHIRClient.new(base_url: "") }
        assert_raises(ArgumentError) { Lakeraven::EHR::EnrollmentFHIRClient.new(base_url: nil) }
      end

      test "check_eligibility posts CoverageEligibilityRequest as FHIR JSON with bearer token" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.enrolled?
        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
        post = transport.posts_to(enrollment_eligibility_post_url).first
        assert_equal "application/fhir+json", post[:headers]["Content-Type"]
        assert_equal "Bearer #{SYNTHETIC_BEARER_TOKEN}", post[:headers]["Authorization"]
        payload = JSON.parse(post[:body])
        assert_equal "CoverageEligibilityRequest", payload["resourceType"]
        assert_equal "medicare_b", result.coverage_type
        assert_equal SYNTHETIC_PATIENT_DFN, result.patient_dfn
      end

      test "omits bearer authorization header when token is nil" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport, token: nil)

        client.check_eligibility(@request)

        post = transport.posts_to(enrollment_eligibility_post_url).first
        refute_includes post[:headers].keys.map(&:downcase), "authorization"
      end

      test "call is an alias for check_eligibility on the eligibility adapter" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_not_enrolled_body, transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

        via_call = client.call(@request)
        transport.reset!
        stub_enrollment_eligibility_post(body: fhir_eligibility_not_enrolled_body, transport: transport)

        via_check = client.check_eligibility(@request)

        assert via_call.not_enrolled?
        assert via_check.not_enrolled?
      end

      test "maps a complete inforce response to enrolled status" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.enrolled?
        refute result.not_enrolled?
        refute result.pending?
      end

      test "maps a complete not-inforce response to not_enrolled status" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_not_enrolled_body, transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.not_enrolled?
        refute result.enrolled?
      end

      test "malformed 2xx JSON yields error status and is not cached" do
        stub_enrollment_eligibility_post(body: "not-json", status: 200, transport: @enrollment_transport)
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        refute result.enrolled?
        assert_empty memory_cache_keys(cache)
      end

      test "malformed 2xx resourceType yields error status and is not cached" do
        stub_enrollment_eligibility_post(body: { resourceType: "Patient", outcome: "complete" }, transport: @enrollment_transport)
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        assert_empty memory_cache_keys(cache)
      end

      test "malformed 2xx missing outcome yields error status and is not cached" do
        stub_enrollment_eligibility_post(
          body: { resourceType: "CoverageEligibilityResponse", insurance: [ { inforce: true } ] },
          transport: @enrollment_transport
        )
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        assert_empty memory_cache_keys(cache)
      end

      test "caches terminal enrolled responses and avoids a second HTTP call within ttl" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport, ttl: 1.hour)

        first = client.check_eligibility(@request)
        second = client.check_eligibility(@request)

        assert first.enrolled?
        assert second.enrolled?
        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
        refute memory_cache_keys(cache).any? { |key| key.include?(SYNTHETIC_PATIENT_DFN) },
               "cache key must not embed the raw patient identifier"
      end

      test "caches terminal not_enrolled responses" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_not_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport)

        client.check_eligibility(@request)
        client.check_eligibility(@request)

        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
        assert memory_cache_keys(cache).any?, "expected a cache entry for not_enrolled"
      end

      test "expires cached eligibility after ttl and calls enrollment again" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        @enrollment_transport.queue_post(
          RecordingFakeEnrollmentHttpTransport::Response.new(
            code: 200,
            body: fhir_eligibility_enrolled_body.to_json
          )
        )
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport, ttl: 1.hour)

        travel_to Time.zone.local(2026, 3, 15, 10, 0, 0) do
          client.check_eligibility(@request)
        end

        travel_to Time.zone.local(2026, 3, 15, 12, 0, 0) do
          client.check_eligibility(@request)
        end

        assert_equal 2, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "pending results are never cached" do
        with_enrollment_job_adapter do
          stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
          client, cache, _, = build_enrollment_client(http: @enrollment_transport)

          result = client.check_eligibility(@request)

          assert result.pending?
          refute result.enrolled?
          refute result.not_enrolled?
          assert_empty memory_cache_keys(cache)
        end
      end

      test "retries transient 5xx and 429 responses with backoff then returns pending and enqueues retry job" do
        with_enrollment_job_adapter do
          sleeps = []
          stub_enrollment_eligibility_post_failures(503, 429, 500, transport: @enrollment_transport)
          client, _, _, transport = build_enrollment_client(http: @enrollment_transport, sleep_log: sleeps)

          assert_enqueued_with(job: Lakeraven::EHR::EnrollmentEligibilityRetryJob) do
            result = client.check_eligibility(@request)

            assert result.pending?
            refute result.enrolled?
            refute result.not_enrolled?
          end

          assert_equal 3, transport.posts_to(enrollment_eligibility_post_url).length
          assert_equal 2, sleeps.length, "expected backoff sleeps between attempts"
        end
      end

      test "retries connection errors then returns pending and enqueues retry job" do
        with_enrollment_job_adapter do
          @enrollment_transport.raise_on_every_post(Errno::ECONNREFUSED)
          client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

          assert_enqueued_with(job: Lakeraven::EHR::EnrollmentEligibilityRetryJob) do
            result = client.check_eligibility(@request)

            assert result.pending?
          end

          assert_equal 3, transport.posts_to(enrollment_eligibility_post_url).length
        end
      end

      test "returns pending and logs fixed line when retry job enqueue raises without PHI" do
        with_enrollment_job_adapter do
          stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
          client, = build_enrollment_client(http: @enrollment_transport)
          request_body = @request.to_fhir.to_json
          original_perform_later = Lakeraven::EHR::EnrollmentEligibilityRetryJob.method(:perform_later)
          Lakeraven::EHR::EnrollmentEligibilityRetryJob.define_singleton_method(:perform_later) do |*_args, **_kwargs|
            raise Redis::CannotConnectError, "synthetic queue failure"
          end

          logs = capture_rails_logs do
            result = client.check_eligibility(@request)
            assert result.pending?
            refute result.enrolled?
            refute result.not_enrolled?
          end

          assert_includes logs, RETRY_ENQUEUE_FAILED_LOG
          refute_includes logs, SYNTHETIC_PATIENT_DFN
          refute_includes logs, SYNTHETIC_BEARER_TOKEN
          refute_includes logs, request_body
        ensure
          Lakeraven::EHR::EnrollmentEligibilityRetryJob.define_singleton_method(:perform_later, original_perform_later)
        end
      end

      test "does not retry non-429 4xx responses" do
        stub_enrollment_eligibility_post(body: { resourceType: "OperationOutcome" }, status: 400, transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        refute result.enrolled?
        refute result.not_enrolled?
        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "failure logging omits patient dfn token and request body when check stays pending" do
        with_enrollment_job_adapter do
          @enrollment_transport.raise_on_every_post(Errno::ETIMEDOUT)
          client, = build_enrollment_client(http: @enrollment_transport)
          request_body = @request.to_fhir.to_json

          logs = capture_rails_logs do
            result = client.check_eligibility(@request)
            assert result.pending?
          end

          refute_includes logs, SYNTHETIC_PATIENT_DFN
          refute_includes logs, SYNTHETIC_BEARER_TOKEN
          refute_includes logs, request_body
        end
      end

      test "coverage_for client error message omits the patient dfn" do
        stub_enrollment_coverage_search(coverages: [], status: 503, transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        error = assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end

        refute_includes error.message, SYNTHETIC_PATIENT_DFN
        refute_includes error.message, SYNTHETIC_BEARER_TOKEN
      end

      test "coverage_for returns FHIR Coverage resources with plan and payor details" do
        stub_enrollment_coverage_search(coverages: [ sample_medicaid_coverage_resource ], transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 1, coverages.length
        assert_equal "Coverage", coverages.first["resourceType"]
        assert_equal "TEST Medicaid Plan", coverages.first.dig("class", 0, "name")
        assert_equal "TEST State Medicaid Payor", coverages.first.dig("payor", 0, "display")
      end

      test "coverage_for searchset with no entry and no total returns empty array without verifying absence" do
        bundle = fhir_empty_coverage_search_bundle_without_total
        stub_enrollment_coverage_search_pages([ bundle ], transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal [], coverages
      end

      test "coverage_for raises a client error on enrollment failure instead of silent empty array" do
        stub_enrollment_coverage_search(coverages: [], status: 503, transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      # --- Round-1 spec: patient reference must match requested DFN exactly --------

      test "2xx response with no patient element yields error not a coverage answer" do
        body = fhir_eligibility_enrolled_body
        body.delete(:patient)
        stub_enrollment_eligibility_post(body: body, transport: @enrollment_transport)
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        refute result.enrolled?
        refute result.not_enrolled?
        assert_empty memory_cache_keys(cache)
      end

      test "2xx response with blank patient reference yields error" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(patient: { reference: "" }),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).error?
      end

      test "2xx response with non-Hash patient yields error" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(patient: "Patient/#{SYNTHETIC_PATIENT_DFN}"),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_nothing_raised do
          assert client.check_eligibility(@request).error?
        end
      end

      test "2xx response for a different patient yields error" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_enrolled_body(patient_dfn: "900002"),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).error?
      end

      # --- Round-3 spec: response must answer this request ------------------------

      test "2xx response with servicedDate for a different service date yields error and is not cached" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(serviced_date: "2026-04-01"),
          transport: @enrollment_transport
        )
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        assert_empty memory_cache_keys(cache)
      end

      test "2xx response with request reference for another CoverageEligibilityRequest yields error" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            request_reference: "CoverageEligibilityRequest/#{SecureRandom.uuid}"
          ),
          transport: @enrollment_transport
        )
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        assert_empty memory_cache_keys(cache)
      end

      test "2xx response with matching servicedDate and request reference yields enrolled" do
        request = build_enrollment_request
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_for_request(request),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(request).enrolled?
      end

      # --- Round-3 spec: CoverageEligibilityResponse.error[] ----------------------

      test "2xx response with transient AAA error code yields pending retry and is not cached" do
        transient_code = Lakeraven::EHR::CoverageEligibilityResponse::TRANSIENT_ERROR_CODES.first
        with_enrollment_job_adapter do
          stub_enrollment_eligibility_post(
            body: fhir_eligibility_response_body(
              outcome: "complete",
              errors: [ fhir_eligibility_error_item(code: transient_code) ]
            ),
            transport: @enrollment_transport
          )
          client, cache, _, = build_enrollment_client(http: @enrollment_transport)

          assert_enqueued_with(job: Lakeraven::EHR::EnrollmentEligibilityRetryJob) do
            result = client.check_eligibility(@request)
            assert result.pending?
            refute result.enrolled?
            refute result.not_enrolled?
          end
          assert_empty memory_cache_keys(cache)
        end
      end

      test "2xx response with non-transient error code yields error and is not cached" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            outcome: "complete",
            errors: [ fhir_eligibility_error_item(code: "99") ]
          ),
          transport: @enrollment_transport
        )
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        refute result.enrolled?
        assert_empty memory_cache_keys(cache)
      end

      # --- Round-1 spec: coverage type matching on insurance items -----------------

      test "in-force insurance for another coverage type does not enroll the requested type" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [ fhir_eligibility_insurance_item(coverage_type: "medicaid", inforce: true) ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        refute result.enrolled?
      end

      test "matching insurance item with inforce true yields enrolled" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(coverage_type: "medicaid", inforce: false),
              fhir_eligibility_insurance_item(coverage_type: "medicare_b", inforce: true)
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).enrolled?
      end

      test "matching insurance items all inforce false yield not_enrolled" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(coverage_type: "medicare_b", inforce: false),
              fhir_eligibility_insurance_item(coverage_type: "MEDICARE_B", inforce: false)
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).not_enrolled?
      end

      test "no insurance item matching requested coverage type yields error" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [ fhir_eligibility_insurance_item(coverage_type: "va_benefits", inforce: true) ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).error?
      end

      test "coverage reference id segment must match requested type exactly not as substring" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              {
                inforce: true,
                coverage: { reference: "Coverage/plan-Medicare_B-synthetic" }
              }
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).error?
      end

      # --- Round-2 spec: exact coverage-type matching --------------------------------

      test "medicare_a request does not match reference id medicare_advantage_x" do
        assert_coverage_reference_yields_error(
          coverage_type: "medicare_a",
          reference: "Coverage/medicare_advantage_x"
        )
      end

      test "medicaid request does not match reference id private_insurance-secondary-to-medicaid" do
        assert_coverage_reference_yields_error(
          coverage_type: "medicaid",
          reference: "Coverage/private_insurance-secondary-to-medicaid"
        )
      end

      test "medicare_b request does not match reference id plan-medicare_benefits-only" do
        assert_coverage_reference_yields_error(
          coverage_type: "medicare_b",
          reference: "Coverage/plan-medicare_benefits-only"
        )
      end

      test "medicaid request does not match reference id not_medicaid" do
        assert_coverage_reference_yields_error(
          coverage_type: "medicaid",
          reference: "Coverage/not_medicaid"
        )
      end

      test "medicaid request matches reference id medicaid exactly" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            coverage_type: "medicaid",
            insurance: [
              { inforce: true, coverage: { reference: "Coverage/medicaid" } }
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)
        request = build_enrollment_request(coverage_type: "medicaid")

        assert client.check_eligibility(request).enrolled?
      end

      test "medicaid request matches coverage display Medicaid case-insensitively" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            coverage_type: "medicaid",
            insurance: [
              { inforce: true, coverage: { display: "Medicaid" } }
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)
        request = build_enrollment_request(coverage_type: "medicaid")

        assert client.check_eligibility(request).enrolled?
      end

      test "insurance item does not match when display and reference disagree on coverage type" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            coverage_type: "medicaid",
            insurance: [
              {
                inforce: true,
                coverage: { display: "Medicaid", reference: "Coverage/medicare_b" }
              }
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)
        request = build_enrollment_request(coverage_type: "medicaid")

        assert client.check_eligibility(request).error?
      end

      # --- Round-1 spec: CoverageEligibilityResponse.status -----------------------

      %w[cancelled entered-in-error draft].each do |bad_status|
        test "CoverageEligibilityResponse status #{bad_status} yields error" do
          stub_enrollment_eligibility_post(
            body: fhir_eligibility_response_body(status: bad_status),
            transport: @enrollment_transport
          )
          client, = build_enrollment_client(http: @enrollment_transport)

          assert client.check_eligibility(@request).error?
        end
      end

      test "CoverageEligibilityResponse with missing status yields error" do
        body = fhir_eligibility_enrolled_body
        body.delete(:status)
        stub_enrollment_eligibility_post(body: body, transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).error?
      end

      # --- Round-1 spec: benefit period vs service date ---------------------------

      test "service date outside matching benefit period yields not_enrolled" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: { start: "2025-01-01", end: "2025-12-31" }
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).not_enrolled?
      end

      test "malformed benefit period on matching insurance yields error" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: { start: "not-a-date", end: "2026-12-31" }
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).error?
      end

      # --- Round-2 spec: FHIR partial dates in benefitPeriod -------------------------

      test "benefit period end YYYY-MM covering March service date yields enrolled when in force" do
        assert_benefit_period_enrollment(
          service_date: Date.new(2026, 3, 15),
          benefit_period: { start: "2026-01-01", end: "2026-03" },
          expected_enrolled: true
        )
      end

      test "benefit period end YYYY-MM before service month yields not_enrolled when in force" do
        assert_benefit_period_enrollment(
          service_date: Date.new(2026, 3, 15),
          benefit_period: { start: "2026-01-01", end: "2026-02" },
          expected_enrolled: false
        )
      end

      test "benefit period start and end YYYY covering service date in that year yields enrolled" do
        assert_benefit_period_enrollment(
          service_date: Date.new(2026, 6, 1),
          benefit_period: { start: "2026", end: "2026" },
          expected_enrolled: true
        )
      end

      %w[--0131 20260131 2026-3-1 2026-13].each do |bad_date|
        test "benefit period date #{bad_date.inspect} is not a FHIR date and yields error" do
          stub_enrollment_eligibility_post(
            body: fhir_eligibility_response_body(
              insurance: [
                fhir_eligibility_insurance_item(
                  coverage_type: "medicare_b",
                  inforce: true,
                  benefit_period: { start: bad_date, end: "2026-12-31" }
                )
              ]
            ),
            transport: @enrollment_transport
          )
          client, = build_enrollment_client(http: @enrollment_transport)

          assert client.check_eligibility(@request).error?
        end
      end

      test "empty benefitPeriod hash is treated as no period and answers from inforce alone" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: {}
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).enrolled?
      end

      test "benefit period start after end yields error not not_enrolled" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: { start: "2026-12-01", end: "2026-01-01" }
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(@request)

        assert result.error?
        refute result.not_enrolled?
        assert_empty memory_cache_keys(cache)
      end

      test "benefitPeriod on matching insurance yields error when request has no service_date" do
        request = build_enrollment_request_without_service_date
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: { start: "2026-01-01", end: "2026-12-31" }
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        result = client.check_eligibility(request)

        assert result.error?
        refute result.not_enrolled?
      end

      test "benefitPeriod dateTime values are compared by calendar date for the service date" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: {
                  start: "2026-01-01T00:00:00Z",
                  end: "2026-12-31T23:59:59Z"
                }
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert client.check_eligibility(@request).enrolled?
      end

      # --- Round-1 spec: malformed insurance and transport errors -----------------

      test "non-Hash insurance entry yields error without raising from check_eligibility" do
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(insurance: [ "not-a-hash" ]),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_nothing_raised do
          assert client.check_eligibility(@request).error?
        end
      end

      %w[Net::HTTPBadResponse Net::HTTPHeaderSyntaxError OpenSSL::SSL::SSLError Zlib::Error].each do |error_class|
        test "retries #{error_class} on eligibility post then pending with retry job" do
          with_enrollment_job_adapter do
            error = error_class.constantize.new("synthetic transport failure")
            @enrollment_transport.raise_on_every_post(error)
            client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

            assert_enqueued_with(job: Lakeraven::EHR::EnrollmentEligibilityRetryJob) do
              assert_nothing_raised do
                result = client.check_eligibility(@request)
                assert result.pending?
                refute result.enrolled?
                refute result.not_enrolled?
              end
            end

            assert_equal 3, transport.posts_to(enrollment_eligibility_post_url).length
          end
        end
      end

      test "coverage_for wraps transport StandardError in ClientError" do
        @enrollment_transport.raise_on_every_get(Zlib::Error.new("synthetic zlib failure"))
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      # --- Round-1 spec: coverage_for bundle rules --------------------------------

      test "coverage_for raises ClientError when beneficiary reference does not match patient dfn" do
        stub_enrollment_coverage_search(
          coverages: [ sample_medicaid_coverage_resource(beneficiary_dfn: "900002") ],
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      test "coverage_for excludes Coverage resources whose status is not active" do
        stub_enrollment_coverage_search(
          coverages: [
            sample_medicaid_coverage_resource(status: "cancelled", id: "cov-cancelled"),
            sample_medicaid_coverage_resource(status: "active", id: "cov-active")
          ],
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 1, coverages.length
        assert_equal "cov-active", coverages.first["id"]
      end

      test "coverage_for excludes Coverage whose type coding does not match requested coverage_type" do
        stub_enrollment_coverage_search(
          coverages: [
            sample_medicaid_coverage_resource(id: "cov-wrong-type", coverage_type: "medicare_b"),
            sample_medicaid_coverage_resource(id: "cov-match", coverage_type: "medicaid")
          ],
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 1, coverages.length
        assert_equal "cov-match", coverages.first["id"]
      end

      test "coverage_for matches requested coverage_type against type.text case-insensitively" do
        stub_enrollment_coverage_search(
          coverages: [
            sample_coverage_resource_with_type_text(
              coverage_type: "medicaid",
              type_text: "Medicaid",
              id: "cov-text-match"
            )
          ],
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 1, coverages.length
        assert_equal "cov-text-match", coverages.first["id"]
      end

      test "coverage_for excludes Coverage whose period ended before today" do
        travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
          stub_enrollment_coverage_search(
            coverages: [
              sample_medicaid_coverage_resource(
                id: "cov-expired",
                period: { start: "2026-01-01", end: "2026-05-31" }
              ),
              sample_medicaid_coverage_resource(
                id: "cov-current",
                period: { start: "2026-01-01", end: "2026-12-31" }
              )
            ],
            transport: @enrollment_transport
          )
          client, = build_enrollment_client(http: @enrollment_transport)

          coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

          assert_equal 1, coverages.length
          assert_equal "cov-current", coverages.first["id"]
        end
      end

      test "coverage_for excludes Coverage whose period starts after today" do
        travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
          stub_enrollment_coverage_search(
            coverages: [
              sample_medicaid_coverage_resource(
                id: "cov-future",
                period: { start: "2026-07-01", end: "2026-12-31" }
              )
            ],
            transport: @enrollment_transport
          )
          client, = build_enrollment_client(http: @enrollment_transport)

          coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

          assert_equal [], coverages
        end
      end

      test "coverage_for raises ClientError when bundle type is not searchset" do
        stub_enrollment_coverage_search(
          coverages: [ sample_medicaid_coverage_resource ],
          transport: @enrollment_transport,
          bundle_type: "collection"
        )
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      test "coverage_for follows relative next link starting with slash on the enrollment origin" do
        page_one = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-relative-slash") ],
          next_url: "/Coverage?page=2"
        )
        page_two = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-relative-slash-page-2") ]
        )
        stub_enrollment_coverage_search_pages([ page_one, page_two ], transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 2, coverages.length
        assert_equal 2, transport.gets_starting_with("#{ENROLLMENT_BASE_URL}/Coverage").length
      end

      test "coverage_for follows relative next link without leading slash on the enrollment origin" do
        page_one = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-relative-bare") ],
          next_url: "Coverage?page=2"
        )
        page_two = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-relative-bare-page-2") ]
        )
        stub_enrollment_coverage_search_pages([ page_one, page_two ], transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 2, coverages.length
        assert_equal 2, transport.gets_starting_with("#{ENROLLMENT_BASE_URL}/Coverage").length
      end

      test "coverage_for raises ClientError when bundle includes OperationOutcome with error severity" do
        bundle = fhir_coverage_search_bundle(coverages: [])
        bundle[:entry] = [
          {
            search: { mode: "outcome" },
            resource: {
              resourceType: "OperationOutcome",
              issue: [ { severity: "error", diagnostics: "synthetic search failure" } ]
            }
          }
        ]
        stub_enrollment_coverage_search_pages([ bundle ], transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      test "coverage_for follows next links on the same https origin and returns all active pages" do
        page_one = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-page-1") ],
          next_url: "#{ENROLLMENT_BASE_URL}/Coverage?page=2"
        )
        page_two = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-page-2") ]
        )
        stub_enrollment_coverage_search_pages([ page_one, page_two ], transport: @enrollment_transport)
        client, _, _, transport = build_enrollment_client(http: @enrollment_transport)

        coverages = client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")

        assert_equal 2, coverages.length
        assert_equal 2, transport.gets_starting_with(enrollment_coverage_search_url).length
      end

      test "coverage_for raises ClientError when next link targets another https origin" do
        page = fhir_coverage_search_bundle(
          coverages: [ sample_medicaid_coverage_resource(id: "cov-page-1") ],
          next_url: "https://other-host.example.test/Coverage?page=2"
        )
        stub_enrollment_coverage_search_pages([ page ], transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      test "coverage_for raises ClientError when more than ten next pages remain" do
        pages = 11.times.map do |index|
          fhir_coverage_search_bundle(
            coverages: [ sample_medicaid_coverage_resource(id: "cov-page-#{index}") ],
            next_url: "#{ENROLLMENT_BASE_URL}/Coverage?page=#{index + 2}"
          )
        end
        stub_enrollment_coverage_search_pages(pages, transport: @enrollment_transport)
        client, = build_enrollment_client(http: @enrollment_transport)

        assert_raises(Lakeraven::EHR::EnrollmentFHIRClient::ClientError) do
          client.coverage_for(patient_dfn: SYNTHETIC_PATIENT_DFN, coverage_type: "medicaid")
        end
      end

      # --- Round-1 spec: cache behavior -------------------------------------------

      test "from_environment defaults cache to Rails.cache" do
        previous_base = ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"]
        ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"] = ENROLLMENT_BASE_URL
        client = Lakeraven::EHR::EnrollmentFHIRClient.from_environment
        cache = client.instance_variable_get(:@cache)
        assert_equal Rails.cache, cache
      ensure
        ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"] = previous_base
      end

      test "cache key material includes base_url so different hosts do not share entries" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        shared_cache = ActiveSupport::Cache.lookup_store(:memory_store)
        client_a, _, _, transport_a = build_enrollment_client(
          http: @enrollment_transport,
          cache: shared_cache,
          base_url: ENROLLMENT_BASE_URL
        )
        client_a.check_eligibility(@request)

        transport_b = RecordingFakeEnrollmentHttpTransport.new
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: transport_b)
        client_b, _, _, = build_enrollment_client(
          http: transport_b,
          cache: shared_cache,
          base_url: ENROLLMENT_ALT_BASE_URL
        )
        client_b.check_eligibility(@request)

        assert_equal 1, transport_b.posts_to(enrollment_eligibility_post_url_for(ENROLLMENT_ALT_BASE_URL)).length
      end

      test "cached terminal answer is ignored when stored patient_dfn does not match request" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport)
        client.check_eligibility(@request)
        transport.reset!
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: transport)

        key = enrollment_cache_key_for(client, @request)
        write_memory_cache_entry(
          cache,
          key,
          {
            "patient_dfn" => "900002",
            "coverage_type" => @request.coverage_type,
            "status" => "enrolled",
            "request_id" => SecureRandom.uuid,
            "start_date" => "2026-01-01",
            "end_date" => "2026-12-31"
          }
        )

        client.check_eligibility(@request)

        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "cached terminal answer is ignored when stored coverage_type does not match request" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport)
        client.check_eligibility(@request)
        transport.reset!
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: transport)

        key = enrollment_cache_key_for(client, @request)
        write_memory_cache_entry(
          cache,
          key,
          {
            "patient_dfn" => @request.patient_dfn,
            "coverage_type" => "medicaid",
            "status" => "enrolled",
            "request_id" => SecureRandom.uuid
          }
        )

        client.check_eligibility(@request)

        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "cached terminal answer is ignored when stored service_date does not match request" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport)
        client.check_eligibility(@request)
        transport.reset!
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: transport)

        key = enrollment_cache_key_for(client, @request)
        write_memory_cache_entry(
          cache,
          key,
          {
            "patient_dfn" => @request.patient_dfn,
            "coverage_type" => @request.coverage_type,
            "status" => "enrolled",
            "request_id" => SecureRandom.uuid,
            "service_date" => "2026-04-01"
          }
        )

        client.check_eligibility(@request)

        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "cache hit returns enrolled status with the current request id" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, _, _, = build_enrollment_client(http: @enrollment_transport)

        first = client.check_eligibility(@request)
        @request.id = SecureRandom.uuid
        second = client.check_eligibility(@request)

        assert second.enrolled?
        assert_equal @request.id, second.request_id
        refute_equal first.request_id, second.request_id
      end

      test "cached payload stores request identity digest not plaintext patient dfn" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        client, cache, _, = build_enrollment_client(http: @enrollment_transport)

        client.check_eligibility(@request)

        entries = memory_cache_entries(cache)
        assert entries.any?, "expected a cached eligibility payload"
        entries.each do |entry|
          next unless entry.is_a?(Hash)

          refute_equal SYNTHETIC_PATIENT_DFN, entry["patient_dfn"]
          refute entry.values.any? { |value| value.to_s.include?(SYNTHETIC_PATIENT_DFN) },
                 "cached value must not embed the raw patient identifier"
          assert entry.key?("request_identity_digest"), "expected digest of request identity in cache payload"
        end
      end

      # --- Round-2 spec: cache reads require full identity -----------------------------

      test "cache entry with only enrolled status is a miss and eligibility is fetched again" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_not_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport)
        client.check_eligibility(@request)
        transport.reset!
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: transport)

        key = enrollment_cache_key_for(client, @request)
        write_memory_cache_entry(cache, key, { "status" => "enrolled" })

        result = client.check_eligibility(@request)

        assert result.enrolled?, "expected fresh service answer, not forged cache status"
        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "cache entry missing request_identity_digest is a miss even when coverage_type and service_date match" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_not_enrolled_body, transport: @enrollment_transport)
        client, cache, _, transport = build_enrollment_client(http: @enrollment_transport)
        client.check_eligibility(@request)
        transport.reset!
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: transport)

        key = enrollment_cache_key_for(client, @request)
        write_memory_cache_entry(
          cache,
          key,
          {
            "status" => "not_enrolled",
            "coverage_type" => @request.coverage_type,
            "service_date" => @request.service_date.iso8601
          }
        )

        result = client.check_eligibility(@request)

        assert result.enrolled?, "expected fresh service answer when digest is absent"
        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      private

      def assert_coverage_reference_yields_error(coverage_type:, reference:)
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            coverage_type: coverage_type,
            insurance: [ { inforce: true, coverage: { reference: reference } } ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)
        request = build_enrollment_request(coverage_type: coverage_type)

        result = client.check_eligibility(request)

        assert result.error?, "expected error for #{coverage_type} vs #{reference}"
        refute result.enrolled?
      end

      def assert_benefit_period_enrollment(service_date:, benefit_period:, expected_enrolled:)
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_response_body(
            insurance: [
              fhir_eligibility_insurance_item(
                coverage_type: "medicare_b",
                inforce: true,
                benefit_period: benefit_period
              )
            ]
          ),
          transport: @enrollment_transport
        )
        client, = build_enrollment_client(http: @enrollment_transport)
        request = build_enrollment_request(service_date: service_date)

        result = client.check_eligibility(request)

        if expected_enrolled
          assert result.enrolled?, "expected enrolled for #{benefit_period.inspect} on #{service_date}"
        else
          assert result.not_enrolled?, "expected not_enrolled for #{benefit_period.inspect} on #{service_date}"
        end
      end
    end
  end
end
