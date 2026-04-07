# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::FHIR::OperationOutcomeTest < ActiveSupport::TestCase
  Outcome = Lakeraven::EHR::FHIR::OperationOutcome

  test "renders resourceType OperationOutcome" do
    result = Outcome.call(severity: "error", code: "not-found", diagnostics: "x")
    assert_equal "OperationOutcome", result[:resourceType]
  end

  test "issue carries severity, code, and diagnostics" do
    result = Outcome.call(severity: "error", code: "not-found", diagnostics: "Patient not found")
    issue = result[:issue].first
    assert_equal "error", issue[:severity]
    assert_equal "not-found", issue[:code]
    assert_equal "Patient not found", issue[:diagnostics]
  end

  test "diagnostics is omitted when nil" do
    result = Outcome.call(severity: "error", code: "required")
    refute result[:issue].first.key?(:diagnostics)
  end

  test "raises ArgumentError for an unknown severity" do
    assert_raises(ArgumentError) { Outcome.call(severity: "panic", code: "not-found") }
  end

  test "accepts the four valid severities: fatal, error, warning, information" do
    %w[fatal error warning information].each do |severity|
      result = Outcome.call(severity: severity, code: "informational")
      assert_equal severity, result[:issue].first[:severity]
    end
  end
end
