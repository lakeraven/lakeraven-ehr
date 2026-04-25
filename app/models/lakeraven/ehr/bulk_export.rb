# frozen_string_literal: true

module Lakeraven
  module EHR
    # BulkExport Model - ActiveModel
    # ONC Certification 170.315(g)(10) - Bulk Data Access
    #
    # Tracks the status of FHIR Bulk Data Export requests.
    # Exports are asynchronous operations that generate NDJSON files
    # for each resource type requested.
    class BulkExport
      include ActiveModel::Model
      include ActiveModel::Attributes

      # Export types
      EXPORT_TYPE_SYSTEM = "system"
      EXPORT_TYPE_PATIENT = "patient"
      EXPORT_TYPE_GROUP = "group"

      EXPORT_TYPES = [ EXPORT_TYPE_SYSTEM, EXPORT_TYPE_PATIENT, EXPORT_TYPE_GROUP ].freeze

      # Export statuses
      STATUS_PENDING = "pending"
      STATUS_PROCESSING = "processing"
      STATUS_COMPLETED = "completed"
      STATUS_FAILED = "failed"
      STATUS_EXPIRED = "expired"

      STATUSES = [ STATUS_PENDING, STATUS_PROCESSING, STATUS_COMPLETED, STATUS_FAILED, STATUS_EXPIRED ].freeze

      # US Core resource types for bulk export
      SUPPORTED_RESOURCES = %w[
        Patient AllergyIntolerance Condition Immunization Medication
        MedicationRequest Observation Procedure DiagnosticReport
        CarePlan CareTeam Goal Device Practitioner Organization
        Location DocumentReference
      ].freeze

      # -- Attributes ----------------------------------------------------------

      attribute :id, :string
      attribute :export_type, :string
      attribute :status, :string
      attribute :request_url, :string
      attribute :output_format, :string
      attribute :group_id, :string
      attribute :since_timestamp, :datetime
      attribute :type_filters, :string
      attribute :client_id, :string
      attribute :started_at, :datetime
      attribute :completed_at, :datetime

      attr_accessor :requested_types, :output_files, :export_errors

      def initialize(attributes = {})
        types = attributes.delete(:requested_types)
        files = attributes.delete(:output_files)
        errors_list = attributes.delete(:export_errors)
        super(attributes)
        @requested_types = types || SUPPORTED_RESOURCES
        @output_files = files || []
        @export_errors = errors_list || []
      end

      # -- Validations ---------------------------------------------------------

      validates :export_type, presence: true, inclusion: { in: EXPORT_TYPES }
      validates :status, presence: true, inclusion: { in: STATUSES }
      validates :request_url, presence: true
      validates :output_format, presence: true

      # -- Defaults ------------------------------------------------------------

      def set_defaults!
        self.status ||= STATUS_PENDING
        self.output_format ||= "application/fhir+ndjson"
        self.requested_types ||= SUPPORTED_RESOURCES
        self.output_files ||= []
        self.export_errors ||= []
      end

      # -- Normalize types -----------------------------------------------------

      def self.normalize_types(types)
        return SUPPORTED_RESOURCES if types.blank?
        requested = types.is_a?(String) ? types.split(",").map(&:strip) : types
        requested & SUPPORTED_RESOURCES
      end

      # -- Status transitions --------------------------------------------------

      def start_processing!
        self.status = STATUS_PROCESSING
        self.started_at = Time.current
      end

      def complete!(files)
        self.status = STATUS_COMPLETED
        self.completed_at = Time.current
        self.output_files = files
      end

      def fail!(error_message)
        self.status = STATUS_FAILED
        self.completed_at = Time.current
        self.export_errors = [ { "type" => "transient", "message" => error_message } ]
      end

      # -- Status predicates ---------------------------------------------------

      def completed?  = status == STATUS_COMPLETED
      def processing? = status == STATUS_PROCESSING
      def pending?    = status == STATUS_PENDING
      def failed?     = status == STATUS_FAILED

      # -- Status response -----------------------------------------------------

      def status_response
        case status
        when STATUS_PENDING, STATUS_PROCESSING
          {
            status: 202,
            headers: {
              "X-Progress" => progress_message,
              "Retry-After" => retry_after
            }
          }
        when STATUS_COMPLETED
          {
            status: 200,
            body: completion_body
          }
        when STATUS_FAILED
          {
            status: 500,
            body: error_outcome
          }
        when STATUS_EXPIRED
          {
            status: 404,
            body: not_found_outcome
          }
        end
      end

      private

      def progress_message
        case status
        when STATUS_PENDING then "Export request queued"
        when STATUS_PROCESSING then "Export in progress"
        end
      end

      def retry_after
        processing? ? "30" : "10"
      end

      def completion_body
        {
          transactionTime: completed_at&.iso8601,
          request: request_url,
          requiresAccessToken: true,
          output: output_files_array,
          error: export_errors.presence || []
        }
      end

      def output_files_array
        (output_files || []).map do |file|
          { type: file["type"], url: file["url"], count: file["count"] }
        end
      end

      def error_outcome
        {
          resourceType: "OperationOutcome",
          issue: (export_errors || []).map do |error|
            {
              severity: "error",
              code: error["type"] || "exception",
              diagnostics: error["message"]
            }
          end
        }
      end

      def not_found_outcome
        {
          resourceType: "OperationOutcome",
          issue: [ {
            severity: "error",
            code: "not-found",
            diagnostics: "Export request has expired or was not found"
          } ]
        }
      end
    end
  end
end
