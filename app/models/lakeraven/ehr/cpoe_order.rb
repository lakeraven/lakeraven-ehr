# frozen_string_literal: true

module Lakeraven
  module EHR
    class CpoeOrder
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :string
      attribute :patient_dfn, :string
      attribute :requester_duz, :string
      attribute :requester_name, :string
      attribute :status, :string, default: "draft"
      attribute :intent, :string, default: "order"
      attribute :category, :string
      attribute :priority, :string, default: "routine"
      attribute :code, :string
      attribute :code_display, :string
      attribute :body_site, :string
      attribute :clinical_reason, :string
      attribute :note, :string
      attribute :authored_on, :datetime
      attribute :signed_at, :datetime
      attribute :signer_duz, :string
      attribute :signed_content_hash, :string

      def draft? = status == "draft"
      def active? = status == "active"
      def completed? = status == "completed"
      def signed? = signed_at.present?

      def sign!(signer_duz:)
        self.signer_duz = signer_duz
        self.signed_at = Time.current
        self.signed_content_hash = Digest::SHA256.hexdigest(signable_content)
        self.status = "active"
      end

      def to_fhir
        {
          resourceType: "ServiceRequest",
          id: id,
          status: status,
          intent: intent,
          priority: priority,
          code: code_display ? { text: code_display } : nil,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          requester: requester_name ? { display: requester_name } : nil
        }.compact
      end

      private

      def signable_content
        [ patient_dfn, code, code_display, dosage_or_instructions ].compact.join("|")
      end

      def dosage_or_instructions
        note || clinical_reason
      end
    end
  end
end
