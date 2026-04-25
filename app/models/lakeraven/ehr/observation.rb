# frozen_string_literal: true

module Lakeraven
  module EHR
    class Observation
      include ActiveModel::Model
      include ActiveModel::Attributes

      # SDOH LOINC codes (ONC 170.315(a)(15))
      SDOH_CODES = {
        housing_status: "71802-3",
        food_insecurity: "88122-7",
        prapare: "93025-5",
        ahc_hrsn: "96777-8",
        financial_strain: "76513-1",
        employment_status: "67875-5"
      }.freeze

      # SOGI LOINC codes
      SOGI_CODES = {
        sexual_orientation: "76690-7",
        gender_identity: "76691-5"
      }.freeze

      # Vital signs LOINC codes
      VITAL_SIGNS_CODES = {
        blood_pressure: "85354-9",
        systolic: "8480-6",
        diastolic: "8462-4",
        heart_rate: "8867-4",
        temperature: "8310-5",
        respiratory_rate: "9279-1",
        oxygen_saturation: "2708-6",
        body_weight: "29463-7",
        body_height: "8302-2",
        bmi: "39156-5"
      }.freeze

      CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/observation-category"

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :code, :string
      attribute :code_system, :string
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
      def sdoh? = category == "social-history" || category == "survey"

      def to_fhir
        if blood_pressure?
          build_blood_pressure_fhir
        else
          build_standard_fhir
        end
      end

      private

      def blood_pressure?
        code == VITAL_SIGNS_CODES[:blood_pressure]
      end

      def build_standard_fhir
        {
          resourceType: "Observation",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          code: build_code,
          valueQuantity: build_value_quantity,
          valueString: sdoh? && value_quantity.blank? ? value : nil,
          category: category ? [ { coding: [ { code: category, system: CATEGORY_SYSTEM } ] } ] : nil
        }.compact
      end

      def build_blood_pressure_fhir
        systolic_val, diastolic_val = (value || "").split("/").map(&:strip)
        {
          resourceType: "Observation",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          code: build_code,
          category: category ? [ { coding: [ { code: category, system: CATEGORY_SYSTEM } ] } ] : nil,
          component: [
            {
              code: { coding: [ { code: VITAL_SIGNS_CODES[:systolic], system: "http://loinc.org" } ] },
              valueQuantity: { value: systolic_val.to_f, unit: "mm[Hg]", code: "mm[Hg]", system: "http://unitsofmeasure.org" }
            },
            {
              code: { coding: [ { code: VITAL_SIGNS_CODES[:diastolic], system: "http://loinc.org" } ] },
              valueQuantity: { value: diastolic_val.to_f, unit: "mm[Hg]", code: "mm[Hg]", system: "http://unitsofmeasure.org" }
            }
          ]
        }.compact
      end

      def build_code
        return nil unless code || display

        result = {}
        if code
          system = resolve_code_system
          result[:coding] = [ { code: code, system: system }.compact ]
        end
        result[:text] = display if display
        result
      end

      def resolve_code_system
        return "http://loinc.org" if code_system == "loinc" || sdoh? || vital_sign?

        nil
      end

      def build_value_quantity
        return nil unless value_quantity

        { value: value_quantity, unit: unit }.compact
      end
    end
  end
end
