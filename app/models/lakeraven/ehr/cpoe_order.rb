# frozen_string_literal: true

require "digest"

module Lakeraven
  module EHR
    class CpoeOrder
      include ActiveModel::Model
      include ActiveModel::Attributes

      class OrderAlreadySignedError < StandardError; end

      # Clinical attributes that become immutable after signing
      SIGNED_ATTRIBUTES = %i[
        patient_dfn category code code_display body_site laterality
        clinical_reason priority
      ].freeze

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
      attribute :laterality, :string
      attribute :clinical_reason, :string
      attribute :note, :string
      attribute :authored_on, :datetime
      attribute :signed_at, :datetime
      attribute :signer_duz, :string
      attribute :signed_content_hash, :string

      def draft? = status == "draft"
      def active? = status == "active"
      def completed? = status == "completed"
      def signed? = signed_content_hash.present?

      def sign!(provider_duz:)
        raise OrderAlreadySignedError, "Order has already been signed" if signed?

        self.status = "active"
        self.intent = "order"
        self.signed_at = Time.current
        self.signer_duz = provider_duz
        self.requester_duz = provider_duz
        self.signed_content_hash = compute_content_hash
      end

      def cancel!
        self.status = "cancelled"
      end

      def content_hash_valid?
        return false unless signed?
        signed_content_hash == compute_content_hash
      end

      def compute_content_hash
        content = [ id, *SIGNED_ATTRIBUTES.map { |attr| public_send(attr) } ].join("|")
        Digest::SHA256.hexdigest(content)
      end

      # Guard signed order attributes against modification
      SIGNED_ATTRIBUTES.each do |attr|
        define_method(:"#{attr}=") do |value|
          if signed? && send(attr) != value
            raise OrderAlreadySignedError, "Cannot modify #{attr} on a signed order"
          end
          super(value)
        end
      end

      # Signature metadata is immutable once set
      %i[signed_content_hash signed_at signer_duz].each do |attr|
        define_method(:"#{attr}=") do |value|
          if send(attr).present? && send(attr) != value
            raise OrderAlreadySignedError, "Cannot modify #{attr} on a signed order"
          end
          super(value)
        end
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
    end
  end
end
