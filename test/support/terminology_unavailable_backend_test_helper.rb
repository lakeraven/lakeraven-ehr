# frozen_string_literal: true

module TerminologyUnavailableBackendTestHelper
  VALUESET_TERMINOLOGY_NOT_SUPPORTED_DIAGNOSTICS =
    "ValueSet expansion is not available on this server."

  def assert_valueset_terminology_not_supported_response
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-supported", body["issue"].first["code"]
    assert_equal "application/fhir+json", response.media_type

    diagnostics = body["issue"].first["diagnostics"]
    assert_equal VALUESET_TERMINOLOGY_NOT_SUPPORTED_DIAGNOSTICS, diagnostics
    refute_match(/iris|vsac|adapter|local|mock|bogus|locla/i, diagnostics)
    refute_match(/#</, diagnostics)
  end

  def assert_single_backend_warning_logged(logs, backend_name)
    warn_lines = logs.each_line.select { |line| line.match?(/\bWARN\b/i) }
    matching = warn_lines.select { |line| line.match?(/#{Regexp.escape(backend_name)}/i) }
    assert_equal 1, matching.size,
                 "Expected exactly one warning log line naming #{backend_name}, got:\n#{logs}"
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
end
