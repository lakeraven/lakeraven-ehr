# frozen_string_literal: true

module Lakeraven
  module EHR
    class CarePlan
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[draft active on-hold revoked completed entered-in-error unknown].freeze
      VALID_INTENTS = %w[proposal plan order option].freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :title, :string
      attribute :description, :string
      attribute :status, :string, default: "active"
      attribute :intent, :string, default: "plan"
      attribute :category, :string
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :author_name, :string

      validates :patient_dfn, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }
      validates :intent, inclusion: { in: VALID_INTENTS }

      def active? = status == "active"
      def persisted? = ien.present?

      def to_fhir
        {
          resourceType: "CarePlan",
          id: ien,
          status: status,
          intent: intent,
          title: title,
          description: description,
          category: build_category,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          period: build_period,
          author: build_author
        }.compact
      end

      private

      def build_category
        return nil unless category

        [ { coding: [ { code: category, system: "http://hl7.org/fhir/us/core/CodeSystem/careplan-category" } ] } ]
      end

      def build_period
        return nil unless period_start || period_end

        p = {}
        p[:start] = period_start.iso8601 if period_start
        p[:end] = period_end.iso8601 if period_end
        p
      end

      def build_author
        return nil unless author_name

        { display: author_name }
      end
    end
  end
end
