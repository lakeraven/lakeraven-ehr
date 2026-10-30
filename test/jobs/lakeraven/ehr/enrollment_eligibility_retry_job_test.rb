# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/enrollment_fhir_test_helpers"

module Lakeraven
  module EHR
    class EnrollmentEligibilityRetryJobTest < ActiveSupport::TestCase
      include EnrollmentFhirTestHelpers
      include ActiveJob::TestHelper

      RETRY_SKIPPED_LOG = "Enrollment eligibility retry skipped: client is not configured"
      RETRY_ERROR_LOG = "Enrollment eligibility retry received error outcome"
      RETRY_EXHAUSTED_LOG = "Enrollment eligibility retry exhausted without terminal outcome"

      setup do
        @enrollment_transport = RecordingFakeEnrollmentHttpTransport.new
        @original_adapter = Lakeraven::EHR.configuration.eligibility_adapter
        @original_base_url = ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"]
        @original_token = ENV["LAKERAVEN_ENROLLMENT_FHIR_TOKEN"]
        @original_from_environment = EnrollmentFHIRClient.method(:from_environment)
        ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"] = ENROLLMENT_BASE_URL
        ENV["LAKERAVEN_ENROLLMENT_FHIR_TOKEN"] = SYNTHETIC_BEARER_TOKEN
        @job_args = {
          patient_dfn: SYNTHETIC_PATIENT_DFN,
          coverage_type: "medicare_b",
          service_date: DEFAULT_SERVICE_DATE.iso8601,
          provider_npi: "1234567890",
          purpose: "benefits",
          base_url: ENROLLMENT_BASE_URL
        }
      end

      teardown do
        Lakeraven::EHR.configuration.eligibility_adapter = @original_adapter
        ENV["LAKERAVEN_ENROLLMENT_FHIR_BASE_URL"] = @original_base_url
        ENV["LAKERAVEN_ENROLLMENT_FHIR_TOKEN"] = @original_token
        EnrollmentFHIRClient.define_singleton_method(:from_environment, @original_from_environment)
      end

      test "job uses integrations queue and does not log job arguments" do
        assert_equal "integrations", EnrollmentEligibilityRetryJob.new.queue_name
        refute EnrollmentEligibilityRetryJob.log_arguments
      end

      test "perform logs fixed message and does not raise when no enrollment client is configured" do
        ENV.delete("LAKERAVEN_ENROLLMENT_FHIR_BASE_URL")
        Lakeraven::EHR.configuration.eligibility_adapter = MockEligibilityAdapter.new
        args = @job_args.merge(base_url: nil)

        logs = capture_rails_logs do
          assert_nothing_raised do
            EnrollmentEligibilityRetryJob.perform_now(**args)
          end
        end

        assert_includes logs, RETRY_SKIPPED_LOG
        refute_includes logs, SYNTHETIC_PATIENT_DFN
        refute_includes logs, SYNTHETIC_BEARER_TOKEN
      end

      test "perform builds client from configured EnrollmentFHIRClient eligibility_adapter" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client

        assert_nothing_raised do
          EnrollmentEligibilityRetryJob.perform_now(**@job_args)
        end

        assert_equal 1, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
        post = @enrollment_transport.posts_to(enrollment_eligibility_post_url).first
        assert_equal "Bearer #{SYNTHETIC_BEARER_TOKEN}", post[:headers]["Authorization"]
      end

      test "perform falls back to environment client when eligibility_adapter is not EnrollmentFHIRClient" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        Lakeraven::EHR.configuration.eligibility_adapter = MockEligibilityAdapter.new
        client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        with_stubbed_from_environment(client) do
          assert_nothing_raised do
            EnrollmentEligibilityRetryJob.perform_now(**@job_args)
          end
        end

        assert_equal 1, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "perform raises Unavailable when eligibility is still pending" do
        stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client

        assert_raises(EnrollmentFHIRClient::Unavailable) do
          EnrollmentEligibilityRetryJob.perform_now(**@job_args)
        end
      end

      test "perform logs exhausted message without dfn after the final pending attempt" do
        stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client
        job = EnrollmentEligibilityRetryJob.new
        job.define_singleton_method(:executions) { 5 }

        logs = capture_rails_logs do
          assert_nothing_raised do
            job.perform(**@job_args)
          end
        end

        assert_includes logs, RETRY_EXHAUSTED_LOG
        refute_includes logs, SYNTHETIC_PATIENT_DFN
      end

      test "perform logs error outcome without raising" do
        stub_enrollment_eligibility_post(body: "not-json", status: 200, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client

        logs = capture_rails_logs do
          assert_nothing_raised do
            EnrollmentEligibilityRetryJob.perform_now(**@job_args)
          end
        end

        assert_includes logs, RETRY_ERROR_LOG
        refute_includes logs, SYNTHETIC_PATIENT_DFN
      end

      test "perform writes terminal enrolled result to the same cache the adapter uses" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        cache = ActiveSupport::Cache.lookup_store(:memory_store)
        adapter_client, _, _, transport = build_enrollment_client(
          http: @enrollment_transport,
          cache: cache,
          schedule_retry: false
        )
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client

        EnrollmentEligibilityRetryJob.perform_now(**@job_args)

        request = build_enrollment_request
        cached = adapter_client.check_eligibility(request)

        assert cached.enrolled?
        assert_equal 1, transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "retry job enqueue omits bearer token from serialized arguments" do
        with_enrollment_job_adapter do
          stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
          client, = build_enrollment_client(http: @enrollment_transport)

          client.check_eligibility(build_enrollment_request)

          job = enqueued_jobs.find { |entry| entry[:job] == Lakeraven::EHR::EnrollmentEligibilityRetryJob }
          assert job, "expected retry job to be enqueued"
          serialized = job[:args].first
          refute serialized.key?("token")
          refute serialized.key?(:token)
          refute_includes serialized.values.compact.map(&:to_s).join, SYNTHETIC_BEARER_TOKEN
        end
      end

      private

      def with_stubbed_from_environment(client)
        EnrollmentFHIRClient.define_singleton_method(:from_environment) { |**_| client }
        yield
      end
    end
  end
end
