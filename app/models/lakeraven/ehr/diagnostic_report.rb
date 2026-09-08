# frozen_string_literal: true

require "base64"

module Lakeraven
  module EHR
    # DiagnosticReport is FIXTURE-SERVED: records are seeded into
    # DiagnosticReportStore (by a deployment that can source them, e.g. the
    # synthetic sandbox) and served through this serializer. There is NO
    # live RPC read path — the previously-cited ORWLRR REPORT LIST wire
    # mapping was never verified against a real RPMS contract and has been
    # removed rather than presumed.
    class DiagnosticReport
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      # R4 diagnostic-report-status (REQUIRED binding). "unknown" is a legal
      # code and is the honest mapping for a blank or unrecognized source
      # status — a report is never promoted to "final" by default: "final"
      # asserts clinical verification, and only a genuinely-final source
      # status may claim it.
      VALID_STATUSES = %w[registered partial preliminary final amended corrected appended cancelled entered-in-error unknown].freeze
      VALID_CATEGORIES = %w[LAB RAD].freeze

      CATEGORY_LAB = "LAB"
      CATEGORY_RAD = "RAD"

      CATEGORY_DISPLAY = { "LAB" => "Laboratory", "RAD" => "Radiology" }.freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :category, :string
      attribute :code, :string
      attribute :code_display, :string
      attribute :status, :string, default: "unknown"
      attribute :effective_datetime, :datetime
      attribute :issued, :datetime
      attribute :performer_name, :string
      attribute :performer_duz, :string
      attribute :conclusion, :string
      attribute :result_iens, :string
      attribute :presented_form, :string

      validates :patient_dfn, presence: true
      validates :code_display, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }
      validates :category, inclusion: { in: VALID_CATEGORIES }, allow_nil: true

      def self.resource_class
        "DiagnosticReport"
      end

      def final? = status == "final"
      def persisted? = ien.present?

      # DiagnosticReport.code is 1..1 in FHIR — a report with no source
      # naming at all cannot be emitted as a valid resource. Serving layers
      # check this and OMIT such a record rather than serve an invalid one.
      def code_present?
        code_display.present? || code.present?
      end

      # Blank/unrecognized statuses serialize as "unknown" — never "final".
      def fhir_status
        VALID_STATUSES.include?(status.to_s) ? status.to_s : "unknown"
      end

      def to_fhir
        {
          resourceType: "DiagnosticReport",
          id: ien,
          status: fhir_status,
          category: build_category,
          code: build_code,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          effectiveDateTime: effective_datetime&.iso8601,
          issued: issued&.iso8601,
          performer: build_performer,
          result: build_results,
          conclusion: conclusion,
          presentedForm: build_presented_form
        }.compact
      end

      private

      def build_code
        return nil unless code_present?

        # Never emit `"text": null` — a code-only report carries coding alone
        # (FHIR JSON forbids null properties; adversarial review finding).
        result = {}
        result[:text] = code_display if code_display.present?
        if code.present?
          system = category == CATEGORY_RAD ? "http://www.ama-assn.org/go/cpt" : "http://loinc.org"
          result[:coding] = [ { code: code, system: system } ]
        end
        result
      end

      def build_category
        return nil unless category

        # Same nil-key rule: an unrecognized category has no display to emit.
        [ { coding: [ { code: category, display: CATEGORY_DISPLAY[category] }.compact ] } ]
      end

      def build_performer
        return nil unless performer_duz

        [ { reference: "Practitioner/#{performer_duz}", display: performer_name }.compact ]
      end

      def build_results
        return nil unless result_iens.present?

        result_iens.split(",").map { |ien_val| { reference: "Observation/#{ien_val.strip}" } }
      end

      def build_presented_form
        return nil unless presented_form.present?

        [ { contentType: "text/plain", data: Base64.strict_encode64(presented_form) } ]
      end
    end
  end
end
