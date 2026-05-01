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

      # US Core vital sign profile URLs
      US_CORE_PROFILES = {
        "85354-9" => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-blood-pressure",
        "8867-4"  => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-heart-rate",
        "8310-5"  => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-body-temperature",
        "9279-1"  => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-respiratory-rate",
        "2708-6"  => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-pulse-oximetry",
        "29463-7" => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-body-weight",
        "8302-2"  => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-body-height",
        "39156-5" => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-bmi"
      }.freeze

      # Map RPMS vital type strings to LOINC codes and UCUM units
      VITAL_TYPE_MAP = {
        "BP"    => { code: "85354-9", display: "Blood Pressure",      unit: "mm[Hg]" },
        "P"     => { code: "8867-4",  display: "Heart Rate",          unit: "/min" },
        "T"     => { code: "8310-5",  display: "Body Temperature",    unit: "[degF]" },
        "R"     => { code: "9279-1",  display: "Respiratory Rate",    unit: "/min" },
        "POX"   => { code: "2708-6",  display: "Oxygen Saturation",   unit: "%" },
        "WT"    => { code: "29463-7", display: "Body Weight",         unit: "[lb_av]" },
        "HT"    => { code: "8302-2",  display: "Body Height",         unit: "[in_i]" },
        "BMI"   => { code: "39156-5", display: "BMI",                 unit: "kg/m2" }
      }.freeze

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

      # Build Observation instances from raw RPC vital hashes.
      # Each hash has { type:, value:, units:, recorded_date: }.
      def self.from_vital_hashes(hashes, patient_dfn:)
        hashes.filter_map do |h|
          mapping = VITAL_TYPE_MAP[h[:type]]
          next unless mapping

          new(
            ien: h[:ien] || SecureRandom.uuid,
            patient_dfn: patient_dfn,
            code: mapping[:code],
            code_system: "loinc",
            display: mapping[:display],
            value: h[:value],
            value_quantity: h[:type] == "BP" ? nil : h[:value],
            unit: mapping[:unit],
            category: "vital-signs",
            status: "final",
            effective_datetime: h[:recorded_date]
          )
        end
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
          meta: build_meta,
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
          meta: build_meta,
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

      def build_meta
        profile_url = US_CORE_PROFILES[code]
        profile_url ? { profile: [ profile_url ] } : nil
      end

      def build_value_quantity
        return nil unless value_quantity

        qty = { value: value_quantity }
        qty[:unit] = unit if unit
        qty[:code] = unit if unit
        qty[:system] = "http://unitsofmeasure.org" if unit
        qty
      end
    end
  end
end
