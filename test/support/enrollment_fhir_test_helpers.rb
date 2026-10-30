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

  def build_enrollment_request_without_service_date(**overrides)
    request = build_enrollment_request(**overrides)
    request.service_date = nil
    request
  end

  ENROLLMENT_ALT_BASE_URL = "https://enrollment-alt.example.test".freeze

  def build_enrollment_client(**options)
    cache = options.delete(:cache) || ActiveSupport::Cache.lookup_store(:memory_store)
    sleeps = options.delete(:sleep_log) || []
    sleeper = options.delete(:sleeper) || ->(seconds) { sleeps << seconds }
    transport = options.delete(:http) || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = transport
    ttl = options.key?(:ttl) ? options.delete(:ttl) : 24.hours
    base_url = options.delete(:base_url) || ENROLLMENT_BASE_URL
    client = Lakeraven::EHR::EnrollmentFHIRClient.new(
      base_url: base_url,
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

  def fhir_eligibility_insurance_item(coverage_type:, inforce:, benefit_period: nil, coverage: nil)
    item = {
      inforce: inforce,
      coverage: coverage || { display: coverage_type }
    }
    item[:benefitPeriod] = benefit_period if benefit_period
    item
  end

  def fhir_eligibility_error_item(code:)
    { code: { coding: [ { code: code.to_s } ] } }
  end

  def fhir_eligibility_response_body(
    patient_dfn: SYNTHETIC_PATIENT_DFN,
    coverage_type: "medicare_b",
    status: "active",
    outcome: "complete",
    insurance: nil,
    patient: nil,
    serviced_date: :omit,
    request_reference: :omit,
    errors: nil
  )
    body = {
      resourceType: "CoverageEligibilityResponse",
      id: SecureRandom.uuid,
      status: status,
      outcome: outcome,
      patient: patient.nil? ? { reference: "Patient/#{patient_dfn}" } : patient,
      insurance: insurance || [
        fhir_eligibility_insurance_item(
          coverage_type: coverage_type,
          inforce: true,
          benefit_period: { start: "2026-01-01", end: "2026-12-31" }
        )
      ]
    }
    body[:servicedDate] = serviced_date unless serviced_date == :omit
    body[:request] = { reference: request_reference } unless request_reference == :omit
    body[:error] = errors if errors
    body
  end

  def fhir_eligibility_response_for_request(request, **overrides)
    fhir_eligibility_response_body(
      patient_dfn: request.patient_dfn,
      coverage_type: request.coverage_type,
      serviced_date: request.service_date.iso8601,
      request_reference: "CoverageEligibilityRequest/#{request.id}",
      **overrides
    )
  end

  def fhir_eligibility_enrolled_body(patient_dfn: SYNTHETIC_PATIENT_DFN, inforce: true, coverage_type: "medicare_b")
    fhir_eligibility_response_body(
      patient_dfn: patient_dfn,
      coverage_type: coverage_type,
      insurance: [
        fhir_eligibility_insurance_item(
          coverage_type: coverage_type,
          inforce: inforce,
          benefit_period: { start: "2026-01-01", end: "2026-12-31" }
        )
      ]
    )
  end

  def fhir_eligibility_not_enrolled_body(coverage_type: "medicare_b")
    fhir_eligibility_response_body(
      coverage_type: coverage_type,
      insurance: [ fhir_eligibility_insurance_item(coverage_type: coverage_type, inforce: false) ]
    )
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

  def fhir_coverage_search_bundle(coverages:, next_url: nil, total: :auto, bundle_type: "searchset")
    bundle = {
      resourceType: "Bundle",
      type: bundle_type,
      entry: coverages.map { |resource| { resource: resource } }
    }
    bundle[:total] = total == :auto ? coverages.length : total unless total == :omit
    bundle[:link] = [ { relation: "next", url: next_url } ] if next_url
    bundle
  end

  def fhir_empty_coverage_search_bundle_without_total
    { resourceType: "Bundle", type: "searchset", entry: [] }
  end

  def stub_enrollment_coverage_search(coverages:, status: 200, transport: nil, next_url: nil, total: :auto, bundle_type: "searchset")
    body = fhir_coverage_search_bundle(
      coverages: coverages,
      next_url: next_url,
      total: total,
      bundle_type: bundle_type
    )

    t = transport || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = t
    t.queue_get(
      RecordingFakeEnrollmentHttpTransport::Response.new(code: status, body: body.to_json)
    )
    t
  end

  def stub_enrollment_coverage_search_pages(pages, transport: nil)
    t = transport || @enrollment_transport || RecordingFakeEnrollmentHttpTransport.new
    @enrollment_transport = t
    pages.each do |page|
      t.queue_get(
        RecordingFakeEnrollmentHttpTransport::Response.new(code: 200, body: page.to_json)
      )
    end
    t
  end

  def sample_medicaid_coverage_resource(
    beneficiary_dfn: SYNTHETIC_PATIENT_DFN,
    status: "active",
    id: "cov-test-1",
    coverage_type: "medicaid",
    period: { start: "2026-01-01", end: "2026-12-31" }
  )
    {
      resourceType: "Coverage",
      id: id,
      status: status,
      beneficiary: { reference: "Patient/#{beneficiary_dfn}" },
      type: { coding: [ { code: coverage_type } ] },
      period: period,
      class: [
        {
          type: { coding: [ { system: "http://terminology.hl7.org/CodeSystem/coverage-class", code: "plan" } ] },
          name: "TEST Medicaid Plan"
        }
      ],
      payor: [ { display: "TEST State Medicaid Payor" } ]
    }
  end

  def sample_coverage_resource_with_type_text(
    coverage_type:,
    type_text:,
    beneficiary_dfn: SYNTHETIC_PATIENT_DFN,
    status: "active",
    id: "cov-type-text",
    period: { start: "2026-01-01", end: "2026-12-31" }
  )
    {
      resourceType: "Coverage",
      id: id,
      status: status,
      beneficiary: { reference: "Patient/#{beneficiary_dfn}" },
      type: { text: type_text },
      period: period
    }
  end

  def memory_cache_keys(cache)
    store = cache.instance_variable_get(:@data)
    store ? store.keys : []
  end

  def memory_cache_entries(cache)
    store = cache.instance_variable_get(:@data)
    return [] unless store.is_a?(Hash)

    store.values.filter_map do |entry|
      if entry.is_a?(Hash) && entry.key?(:value)
        entry[:value]
      elsif entry.respond_to?(:value)
        entry.value
      end
    end
  end

  def write_memory_cache_entry(cache, key, value, expires_in: 1.hour)
    cache.write(key, value, expires_in: expires_in)
  end

  def enrollment_cache_key_for(client, request)
    client.send(:cache_key, request)
  end

  def enrollment_eligibility_post_url_for(base_url)
    "#{base_url}/CoverageEligibilityRequest"
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
