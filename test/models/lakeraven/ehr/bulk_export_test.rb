# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BulkExportTest < ActiveSupport::TestCase
      # =============================================================================
      # CREATION AND DEFAULTS
      # =============================================================================

      test "creates export with default values" do
        export = BulkExport.new(
          request_url: "http://example.com/fhir/$export",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM
        )
        export.set_defaults!

        assert_equal BulkExport::STATUS_PENDING, export.status
        assert_equal "application/fhir+ndjson", export.output_format
        assert_equal BulkExport::SUPPORTED_RESOURCES, export.requested_types
      end

      test "validates export_type presence" do
        export = BulkExport.new(request_url: "http://example.com")
        assert_not export.valid?
        assert_includes export.errors[:export_type], "can't be blank"
      end

      test "validates export_type inclusion" do
        export = BulkExport.new(request_url: "http://example.com", export_type: "invalid")
        assert_not export.valid?
        assert_includes export.errors[:export_type], "is not included in the list"
      end

      test "validates status presence" do
        export = BulkExport.new(
          request_url: "http://example.com",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: nil
        )
        assert_not export.valid?
        assert_includes export.errors[:status], "can't be blank"
      end

      test "validates request_url presence" do
        export = BulkExport.new(
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_PENDING
        )
        assert_not export.valid?
        assert_includes export.errors[:request_url], "can't be blank"
      end

      test "validates output_format presence" do
        export = BulkExport.new(
          request_url: "http://example.com",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_PENDING,
          output_format: nil
        )
        assert_not export.valid?
        assert_includes export.errors[:output_format], "can't be blank"
      end

      # =============================================================================
      # STATUS TRANSITIONS
      # =============================================================================

      test "start_processing updates status" do
        export = build_export
        export.start_processing!

        assert_equal BulkExport::STATUS_PROCESSING, export.status
        assert_not_nil export.started_at
      end

      test "complete updates status and output_files" do
        export = build_export
        export.start_processing!

        files = [ { "type" => "Patient", "url" => "http://example.com/file.ndjson", "count" => 10 } ]
        export.complete!(files)

        assert_equal BulkExport::STATUS_COMPLETED, export.status
        assert_not_nil export.completed_at
        assert_equal files, export.output_files
      end

      test "fail updates status and errors" do
        export = build_export
        export.start_processing!
        export.fail!("Test error")

        assert_equal BulkExport::STATUS_FAILED, export.status
        assert_equal [ { "type" => "transient", "message" => "Test error" } ], export.export_errors
      end

      # =============================================================================
      # NORMALIZE TYPES
      # =============================================================================

      test "normalize_types filters unsupported resources" do
        types = BulkExport.normalize_types("Patient,Invalid,Condition,Fake")
        assert_equal %w[Patient Condition], types
      end

      test "normalize_types returns all supported when blank" do
        types = BulkExport.normalize_types(nil)
        assert_equal BulkExport::SUPPORTED_RESOURCES, types

        types = BulkExport.normalize_types("")
        assert_equal BulkExport::SUPPORTED_RESOURCES, types
      end

      # =============================================================================
      # STATUS PREDICATES
      # =============================================================================

      test "status predicates work correctly" do
        export = build_export

        assert export.pending?
        assert_not export.processing?
        assert_not export.completed?
        assert_not export.failed?

        export.start_processing!
        assert_not export.pending?
        assert export.processing?

        export.complete!([])
        assert export.completed?
        assert_not export.processing?
      end

      # =============================================================================
      # STATUS RESPONSE
      # =============================================================================

      test "status_response returns 202 for pending" do
        export = build_export
        response = export.status_response

        assert_equal 202, response[:status]
        assert_includes response[:headers]["X-Progress"], "queued"
      end

      test "status_response returns 200 for completed" do
        export = build_export
        export.start_processing!
        export.complete!([])

        response = export.status_response

        assert_equal 200, response[:status]
        assert_equal "http://example.com/fhir/$export", response[:body][:request]
      end

      test "status_response returns 500 for failed" do
        export = build_export
        export.start_processing!
        export.fail!("Something broke")

        response = export.status_response
        assert_equal 500, response[:status]
        assert_equal "OperationOutcome", response[:body][:resourceType]
      end

      private

      def build_export(overrides = {})
        defaults = {
          request_url: "http://example.com/fhir/$export",
          export_type: BulkExport::EXPORT_TYPE_SYSTEM,
          status: BulkExport::STATUS_PENDING,
          output_format: "application/fhir+ndjson",
          requested_types: BulkExport::SUPPORTED_RESOURCES,
          output_files: [],
          export_errors: []
        }
        BulkExport.new(defaults.merge(overrides))
      end
    end
  end
end
