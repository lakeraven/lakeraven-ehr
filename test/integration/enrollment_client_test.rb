# frozen_string_literal: true

require "test_helper"
require_relative "../support/enrollment_fhir_test_helpers"

class EnrollmentClientIntegrationTest < ActiveSupport::TestCase
  include EnrollmentFhirTestHelpers

  setup do
    WebMock.disable_net_connect!
    @original_adapter = Lakeraven::EHR.configuration.eligibility_adapter
    client, = build_enrollment_client(token: nil)
    @client = client
    Lakeraven::EHR.configuration.eligibility_adapter = @client
    @request = build_enrollment_request(coverage_type: "medicare_a")
  end

  teardown do
    WebMock.reset!
    Lakeraven::EHR.configuration.eligibility_adapter = @original_adapter
  end

  test "EligibilityCheck uses EnrollmentFhirClient configured as eligibility_adapter" do
    stub = stub_request(:post, enrollment_eligibility_post_url)
      .with(headers: { "Content-Type" => "application/fhir+json" })
      .to_return(
        status: 200,
        body: fhir_eligibility_enrolled_body(inforce: true).to_json,
        headers: { "Content-Type" => "application/fhir+json" }
      )

    result = Lakeraven::EHR::EligibilityCheck.call(@request)

    assert result.enrolled?
    assert_equal "medicare_a", result.coverage_type
    assert_requested stub, times: 1
  end
end
