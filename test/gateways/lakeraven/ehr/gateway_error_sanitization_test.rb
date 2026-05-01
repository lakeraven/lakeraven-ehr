# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class GatewayErrorSanitizationTest < ActiveSupport::TestCase
      test "sanitizes patient name in error messages" do
        error_msg = "Patient SMITH,JOHN DOE (DFN: 12345) record locked"
        sanitized = PhiSanitizer.sanitize_message(error_msg)

        refute_includes sanitized, "SMITH"
        refute_includes sanitized, "JOHN"
        assert_includes sanitized, "[NAME-REDACTED]"
      end

      test "sanitizes SSN in error messages" do
        error_msg = "Patient SSN: 123-45-6789 not found"
        sanitized = PhiSanitizer.sanitize_message(error_msg)

        refute_includes sanitized, "123-45-6789"
        assert_includes sanitized, "[SSN-REDACTED]"
      end

      test "sanitizes RPMS caret-delimited error with PHI" do
        raw_error = "~`0^Patient JONES,MARY ANN (HRN: 987654) not eligible for CHS"
        error_msg = raw_error.split("^", 2)[1]
        sanitized = PhiSanitizer.sanitize_message(error_msg)

        refute_includes sanitized, "JONES"
        refute_includes sanitized, "MARY"
        refute_includes sanitized, "987654"
      end

      test "sanitizes phone numbers in error messages" do
        error_msg = "Validation failed for phone 907-555-0123 invalid format"
        sanitized = PhiSanitizer.sanitize_message(error_msg)

        refute_includes sanitized, "907-555-0123"
        assert_includes sanitized, "[PHONE-REDACTED]"
      end

      test "sanitizes complex error with multiple PHI types" do
        error_msg = "Error for patient JOHNSON,WILLIAM (DFN: 67890) SSN: 456-78-9012 Phone: (907) 555-9876"
        sanitized = PhiSanitizer.sanitize_message(error_msg)

        refute_includes sanitized, "JOHNSON"
        refute_includes sanitized, "WILLIAM"
        refute_includes sanitized, "67890"
        refute_includes sanitized, "456-78-9012"
        refute_includes sanitized, "555-9876"
      end
    end
  end
end
