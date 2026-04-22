# frozen_string_literal: true

module Lakeraven
  module EHR
    class DocumentReference
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :string
      attribute :status, :string, default: "current"
      attribute :type_code, :string
      attribute :type_display, :string
      attribute :category, :string
      attribute :subject_patient_dfn, :string
      attribute :author_ien, :string
      attribute :date, :datetime
      attribute :description, :string
      attribute :content_url, :string
      attribute :content_type, :string

      def current? = status == "current"

      def to_fhir
        {
          resourceType: "DocumentReference",
          status: status,
          type: type_display ? { text: type_display } : nil,
          subject: subject_patient_dfn ? { reference: "Patient/#{subject_patient_dfn}" } : nil,
          description: description,
          content: content_url ? [ { attachment: { url: content_url, contentType: content_type } } ] : []
        }.compact
      end
    end
  end
end
