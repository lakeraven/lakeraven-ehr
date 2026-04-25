# frozen_string_literal: true

module Lakeraven
  module EHR
    class Observation
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :display, :string
      attribute :value, :string
      attribute :value_quantity, :string
      attribute :unit, :string
      attribute :category, :string
      attribute :status, :string
      attribute :effective_datetime, :datetime

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || ObservationGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      def vital_sign? = category == "vital-signs"
      def laboratory? = category == "laboratory"

      def to_fhir
        {
          resourceType: "Observation",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          code: build_code,
          valueQuantity: build_value_quantity,
          category: category ? [ { coding: [ { code: category } ] } ] : nil
        }.compact
      end

      private

      def build_code
        return nil unless code || display

        result = {}
        result[:coding] = [ { code: code } ] if code
        result[:text] = display if display
        result
      end

      def build_value_quantity
        return nil unless value_quantity

        { value: value_quantity, unit: unit }.compact
      end
    end
  end
end
