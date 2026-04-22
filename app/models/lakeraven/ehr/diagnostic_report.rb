# frozen_string_literal: true

module Lakeraven
  module EHR
    class DiagnosticReport
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :category, :string
      attribute :code, :string
      attribute :code_display, :string
      attribute :status, :string, default: "final"
      attribute :effective_datetime, :datetime
      attribute :issued, :datetime
      attribute :performer_name, :string
      attribute :conclusion, :string

      def final? = status == "final"

      def to_fhir
        {
          resourceType: "DiagnosticReport",
          id: ien,
          status: status,
          code: { text: code_display },
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          conclusion: conclusion
        }.compact
      end
    end
  end
end
