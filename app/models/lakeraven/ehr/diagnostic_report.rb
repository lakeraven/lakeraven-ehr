# frozen_string_literal: true

require "base64"

module Lakeraven
  module EHR
    class DiagnosticReport
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[registered partial preliminary final amended corrected appended cancelled entered-in-error].freeze
      VALID_CATEGORIES = %w[LAB RAD].freeze

      CATEGORY_LAB = "LAB"
      CATEGORY_RAD = "RAD"

      CATEGORY_DISPLAY = { "LAB" => "Laboratory", "RAD" => "Radiology" }.freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :category, :string
      attribute :code, :string
      attribute :code_display, :string
      attribute :status, :string, default: "final"
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

      def final? = status == "final"
      def persisted? = ien.present?

      def to_fhir
        {
          resourceType: "DiagnosticReport",
          id: ien,
          status: status,
          category: build_category,
          code: build_code,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          effectiveDateTime: effective_datetime&.iso8601,
          performer: build_performer,
          result: build_results,
          conclusion: conclusion,
          presentedForm: build_presented_form
        }.compact
      end

      private

      def build_code
        return nil unless code_display || code

        result = { text: code_display }
        if code.present?
          system = category == CATEGORY_RAD ? "http://www.ama-assn.org/go/cpt" : "http://loinc.org"
          result[:coding] = [ { code: code, system: system } ]
        end
        result
      end

      def build_category
        return nil unless category

        display = CATEGORY_DISPLAY[category]
        [ { coding: [ { code: category, display: display } ] } ]
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
