# frozen_string_literal: true

require_relative "recording_fake_enrollment_http_transport"
require "active_job/test_helper"

module EnrollmentFhirTestHelpers
  ENROLLMENT_HOST = "enrollment.example.test"
  ENROLLMENT_BASE_URL = "https://#{ENROLLMENT_HOST}".freeze
  SYNTHETIC_PATIENT_DFN = "900001"
  SYNTHETIC_PATIENT_NAME = "TEST,PATIENT ONE"
  SYNTHETIC_BEARER_TOKEN = "synthetic-enrollment-bearer-token-for-tests"
  DEFAULT_SERVICE_DATE = Date.new(2026, 3, 15)

  def enrollment_eligibility_post_url
    "#{ENROLLMENT_BASE_URL}/CoverageEligibilityRequest"
  end

  def enrollment_coverage_search_url
    "#{ENROLLMENT_BASE_URL}/Coverage"
  end

  def build_enrollment_request(overrides = {})
    Lakeraven::EHR::CoverageEligibilityRequest.new({
      patient_dfn: SYNTHETIC_PATIENT_DFN,
      coverage_type: "medicare_b",
      service_date: DEFAULT_SERVICE_DATE,
      provider_npi: "1234567890"
    }.merge(overrides))
  end

  def build_enrollment_client(**options)
    cache = options.delete(:cache) || ActiveSupport::Cache.lookup_store(:memory_store)
    sleeps = options.delete(:sleep_log) || []
    sleeper = options.delete(:sleeper) || ->(seconds) { sleeps << seconds }
    transport = options.delete(:http) || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = transport
    ttl = options.key?(:ttl) ? options.delete(:ttl) : 24.hours
    client = Lakeraven::EHR::EnrollmentFHIRClient.new(
      base_url: ENROLLMENT_BASE_URL,
      token: SYNTHETIC_BEARER_TOKEN,
      cache: cache,
      ttl: ttl,
      max_attempts: 3,
      sleeper: sleeper,
      http: transport,
      **options
    )
    [ client, cache, sleeps, transport ]
  end

  def fhir_eligibility_enrolled_body(patient_dfn: SYNTHETIC_PATIENT_DFN, inforce: true)
    {
      resourceType: "CoverageEligibilityResponse",
      id: SecureRandom.uuid,
      outcome: "complete",
      patient: { reference: "Patient/#{patient_dfn}" },
      insurance: [ { inforce: inforce, benefitPeriod: { start: "2026-01-01", end: "2026-12-31" } } ]
    }
  end

  def fhir_eligibility_not_enrolled_body
    {
      resourceType: "CoverageEligibilityResponse",
      id: SecureRandom.uuid,
      outcome: "complete",
      patient: { reference: "Patient/#{SYNTHETIC_PATIENT_DFN}" },
      insurance: [ { inforce: false } ]
    }
  end

  def stub_enrollment_eligibility_post(body:, status: 200, transport: nil)
    t = transport || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = t
    t.queue_post(
      RecordingFakeEnrollmentHttpTransport::Response.new(
        code: status,
        body: body.is_a?(String) ? body : body.to_json
      )
    )
    t
  end

  def stub_enrollment_eligibility_post_failures(*statuses, transport: nil)
    t = transport || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = t
    statuses.each { |status| t.queue_post(status: status, body: "") }
    t
  end

  def stub_enrollment_coverage_search(coverages:, status: 200, transport: nil)
    body =
      if coverages.empty?
        { resourceType: "Bundle", type: "searchset", total: 0, entry: [] }
      else
        {
          resourceType: "Bundle",
          type: "searchset",
          total: coverages.length,
          entry: coverages.map { |resource| { resource: resource } }
        }
      end

    t = transport || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = t
    t.queue_get(
      RecordingFakeEnrollmentHttpTransport::Response.new(code: status, body: body.to_json)
    )
    t
  end

  def sample_medicaid_coverage_resource
    {
      resourceType: "Coverage",
      id: "cov-test-1",
      status: "active",
      beneficiary: { reference: "Patient/#{SYNTHETIC_PATIENT_DFN}" },
      class: [
        {
          type: { coding: [ { system: "http://terminology.hl7.org/CodeSystem/coverage-class", code: "plan" } ] },
          name: "TEST Medicaid Plan"
        }
      ],
      payor: [ { display: "TEST State Medicaid Payor" } ]
    }
  end

  def memory_cache_keys(cache)
    store = cache.instance_variable_get(:@data)
    store ? store.keys : []
  end

  def capture_rails_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    previous = Rails.logger
    Rails.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous
  end

  def with_enrollment_job_adapter
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous
  end
end
