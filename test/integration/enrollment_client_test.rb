# frozen_string_literal: true

require "test_helper"
require_relative "../support/enrollment_fhir_test_helpers"

class EnrollmentClientIntegrationTest < ActiveSupport::TestCase
  include EnrollmentFhirTestHelpers

  setup do
    @enrollment_transport = RecordingFakeEnrollmentHttpTransport.new
    @original_adapter = Lakeraven::EHR.configuration.eligibility_adapter
    stub_enrollment_eligibility_post(
      body: fhir_eligibility_enrolled_body(inforce: true, coverage_type: "medicare_a"),
      transport: @enrollment_transport
    )
    client, _, _, = build_enrollment_client(http: @enrollment_transport, token: nil)
    @client = client
    Lakeraven::EHR.configuration.eligibility_adapter = @client
    @request = build_enrollment_request(coverage_type: "medicare_a")
  end

  teardown do
    Lakeraven::EHR.configuration.eligibility_adapter = @original_adapter
  end

  test "EligibilityCheck uses EnrollmentFHIRClient configured as eligibility_adapter" do
    result = Lakeraven::EHR::EligibilityCheck.call(@request)

    assert result.enrolled?
    assert_equal "medicare_a", result.coverage_type
    assert_equal 1, @enrollment_transport.posts_to(enrollment_eligibility_post_url).length
    post = @enrollment_transport.posts_to(enrollment_eligibility_post_url).first
    assert_equal "application/fhir+json", post[:headers]["Content-Type"]
    refute_includes post[:headers].keys.map(&:downcase), "authorization"
  end
end
