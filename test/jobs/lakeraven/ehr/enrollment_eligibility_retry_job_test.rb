# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/enrollment_fhir_test_helpers"

module Lakeraven
  module EHR
    class EnrollmentEligibilityRetryJobTest < ActiveSupport::TestCase
      include EnrollmentFhirTestHelpers
      include ActiveJob::TestHelper

      RETRY_SKIPPED_LOG = "Enrollment eligibility retry skipped: client is not configured"
      RETRY_ENDPOINT_CHANGED_LOG = "Enrollment eligibility retry skipped: endpoint changed"
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

      test "perform_now does not raise when eligibility is still pending and Active Job will retry" do
        stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client
        mid_retry_job = Class.new(EnrollmentEligibilityRetryJob) do
          def executions
            1
          end
        end

        assert_nothing_raised do
          mid_retry_job.perform_now(**@job_args)
        end
      end

      test "perform_now does not raise on the final exhausted pending attempt" do
        stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client
        exhausted_job = Class.new(EnrollmentEligibilityRetryJob) do
          def executions
            EnrollmentEligibilityRetryJob::MAX_ATTEMPTS
          end
        end

        logs = capture_rails_logs do
          assert_nothing_raised do
            exhausted_job.perform_now(**@job_args)
          end
        end

        assert_includes logs, RETRY_EXHAUSTED_LOG
      end

      test "perform does not enqueue another enrollment eligibility retry job when adapter leaves schedule_retry enabled" do
        with_enrollment_job_adapter do
          stub_enrollment_eligibility_post_failures(503, 503, 503, transport: @enrollment_transport)
          adapter_client, = build_enrollment_client(http: @enrollment_transport)
          Lakeraven::EHR.configuration.eligibility_adapter = adapter_client
          clear_enqueued_jobs
          job = EnrollmentEligibilityRetryJob.new
          job.define_singleton_method(:executions) { 1 }

          assert_raises(EnrollmentFHIRClient::Unavailable) do
            job.perform(**@job_args)
          end

          assert_empty enqueued_jobs.select { |entry| entry[:job] == EnrollmentEligibilityRetryJob },
                       "retry job must not schedule another EnrollmentEligibilityRetryJob"
        end
      end

      # Round-3 spec (replaces round-2 rule that job uses its base_url argument): retry
      # only calls the currently configured endpoint; a mismatched queued base_url
      # is skipped without sending PHI or the token to the stale host.
      test "perform logs endpoint changed and makes no request when job base_url differs from configured adapter" do
        alt_transport = RecordingFakeEnrollmentHttpTransport.new
        stub_enrollment_eligibility_post(
          body: fhir_eligibility_enrolled_body,
          transport: alt_transport
        )
        primary_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = primary_client
        args = @job_args.merge(base_url: ENROLLMENT_ALT_BASE_URL)

        logs = capture_rails_logs do
          EnrollmentEligibilityRetryJob.perform_now(**args)
        end

        assert_includes logs, RETRY_ENDPOINT_CHANGED_LOG
        assert_empty alt_transport.posts_to(enrollment_eligibility_post_url_for(ENROLLMENT_ALT_BASE_URL))
        assert_empty @enrollment_transport.posts_to(enrollment_eligibility_post_url)
        refute_includes logs, SYNTHETIC_PATIENT_DFN
        refute_includes logs, SYNTHETIC_BEARER_TOKEN
      end

      test "perform uses configured adapter endpoint when job base_url matches" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client

        EnrollmentEligibilityRetryJob.perform_now(**@job_args)

        assert_equal 1, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
      end

      test "perform falls back to configured adapter base_url when job base_url is nil" do
        stub_enrollment_eligibility_post(body: fhir_eligibility_enrolled_body, transport: @enrollment_transport)
        adapter_client, = build_enrollment_client(http: @enrollment_transport, schedule_retry: false)
        Lakeraven::EHR.configuration.eligibility_adapter = adapter_client
        args = @job_args.merge(base_url: nil)

        EnrollmentEligibilityRetryJob.perform_now(**args)

        assert_equal 1, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
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
