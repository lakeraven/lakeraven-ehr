# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/enrollment_fhir_test_helpers"

module Lakeraven
  module EHR
    class EnrollmentFHIRClientTest < ActiveSupport::TestCase
      include EnrollmentFhirTestHelpers
      include ActiveJob::TestHelper
      include ActiveSupport::Testing::TimeHelpers

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

      test "coverage_for empty search result returns empty array without claiming absent coverage" do
        stub_enrollment_coverage_search(coverages: [], transport: @enrollment_transport)
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
    end
  end
end
