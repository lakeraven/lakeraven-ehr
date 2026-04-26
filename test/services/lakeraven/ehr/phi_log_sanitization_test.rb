# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PhiLogSanitizationTest < ActiveSupport::TestCase
      # =========================================================================
      # PhiSanitizer.safe_patient_context
      # =========================================================================

      test "safe_patient_context returns hashed patient_id_hash" do
        result = PhiSanitizer.safe_patient_context("12345")

        assert_equal [ :patient_id_hash ], result.keys
        assert result[:patient_id_hash].present?
        assert_not_equal "12345", result[:patient_id_hash]
      end

      test "safe_patient_context returns consistent hash for same DFN" do
        hash1 = PhiSanitizer.safe_patient_context("12345")
        hash2 = PhiSanitizer.safe_patient_context("12345")

        assert_equal hash1[:patient_id_hash], hash2[:patient_id_hash]
      end

      test "safe_patient_context returns nil hash for blank DFN" do
        result = PhiSanitizer.safe_patient_context(nil)

        assert_nil result[:patient_id_hash]
      end

      # =========================================================================
      # PhiSanitizer.hash_identifier
      # =========================================================================

      test "hash_identifier returns 12-character hash" do
        hash = PhiSanitizer.hash_identifier("12345")

        assert_equal 12, hash.length
      end

      test "hash_identifier returns nil for nil input" do
        assert_nil PhiSanitizer.hash_identifier(nil)
      end

      test "hash_identifier returns nil for empty string" do
        assert_nil PhiSanitizer.hash_identifier("")
      end

      # =========================================================================
      # PhiSanitizer.sanitize_message
      # =========================================================================

      test "sanitize_message redacts DFN patterns" do
        sanitized = PhiSanitizer.sanitize_message("Error for DFN: 12345")

        assert_includes sanitized, "[REDACTED]"
        assert_not_includes sanitized, "12345"
      end

      test "sanitize_message redacts SSN patterns" do
        sanitized = PhiSanitizer.sanitize_message("SSN is 123-45-6789")

        assert_includes sanitized, "[SSN-REDACTED]"
        assert_not_includes sanitized, "123-45-6789"
      end

      test "sanitize_message returns empty string for nil" do
        assert_equal "", PhiSanitizer.sanitize_message(nil)
      end

      # =========================================================================
      # PhiSanitizer.sanitize_hash
      # =========================================================================

      test "sanitize_hash hashes PHI fields" do
        result = PhiSanitizer.sanitize_hash({ patient_dfn: "12345", status: "active" })

        assert result.key?(:patient_id_hash)
        assert_not result.key?(:patient_dfn)
        assert_equal "active", result[:status]
      end

      test "sanitize_hash redacts SSN fields" do
        result = PhiSanitizer.sanitize_hash({ ssn: "123456789", name: "Test" })

        assert result.key?(:ssn_present)
        assert_equal true, result[:ssn_present]
        assert_not result.key?(:ssn)
      end

      test "sanitize_hash returns empty hash for nil" do
        assert_equal({}, PhiSanitizer.sanitize_hash(nil))
      end

      # =========================================================================
      # NO RAW PHI IN LOG CALLS
      # =========================================================================

      test "no service files pass raw patient_dfn to structured log calls" do
        service_dir = File.expand_path("../../../../app/services", __dir__)
        service_files = Dir[File.join(service_dir, "**/*.rb")]
        offenders = []

        service_files.each do |file|
          content = File.read(file)
          next if file.include?("phi_sanitizer")

          content.to_enum(:scan, /log_(info|warn|error)\s*\([^)]*patient_dfn:[^)]*\)/m).each do
            match = Regexp.last_match
            snippet = match[0]
            next if snippet.lstrip.start_with?("#")

            start_pos = match.begin(0)
            lineno = content[0...start_pos].count("\n") + 1
            offenders << "#{File.basename(file)}:#{lineno}"
          end
        end

        assert_empty offenders,
          "Found raw patient_dfn in log calls: #{offenders.join(', ')}"
      end
    end
  end
end
