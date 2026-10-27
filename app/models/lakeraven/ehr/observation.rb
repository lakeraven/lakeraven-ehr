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
      UCUM_SYSTEM = "http://unitsofmeasure.org"

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

      # Map ORQQVI VITALS type strings to LOINC codes and UCUM units.
      # On RPMS (DUZ("AG")="I") VITAL^ORQQVI answers from MSR^ORQQVI, which
      # reads V MEASUREMENT and names each type by its IHS MEASUREMENT TYPE
      # (#9999999.07) code: TMP, PU, RS, O2. Elsewhere the same routine reads
      # GMRV and answers VistA's T, P, R, POX. Both are real replies of the
      # one RPC, so both are mapped.
      VITAL_TYPE_MAP = {
        "TMP"   => { code: "8310-5",  display: "Body Temperature",    unit: "[degF]" },
        "PU"    => { code: "8867-4",  display: "Heart Rate",          unit: "/min" },
        "RS"    => { code: "9279-1",  display: "Respiratory Rate",    unit: "/min" },
        "O2"    => { code: "2708-6",  display: "Oxygen Saturation",   unit: "%" },
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
      #
      # ORQQVI VITALS carries no IEN, so when one is absent derive a
      # DETERMINISTIC id from dfn + vital type (+ timestamp when present) —
      # never a random uuid — so ids/fullUrls are stable across requests.
      def self.from_vital_hashes(hashes, patient_dfn:)
        hashes.filter_map { |hash| vital_from_hash(hash, patient_dfn) }
      end

      # Unmapped RPMS types (PAIN) stay on the resource as code.text. A row
      # that states units keeps those units; the map's UCUM unit is only the
      # fallback when the row says nothing.
      def self.vital_from_hash(hash, patient_dfn)
        type = hash[:type]
        return if type.blank?

        mapping = VITAL_TYPE_MAP[type]
        new(vital_attributes(hash, patient_dfn, type, mapping))
      end

      def self.vital_attributes(hash, patient_dfn, type, mapping)
        {
          # ORQQVI VITALS names the V MEASUREMENT IEN :measurement_ien since
          # rpms-rpc #188; :ien is what the earlier mapping called it.
          ien: (hash[:measurement_ien] || hash[:ien])&.to_s.presence || vital_id(patient_dfn, hash),
          patient_dfn: patient_dfn,
          code: mapping&.dig(:code),
          code_system: ("loinc" if mapping),
          display: mapping&.dig(:display) || type.to_s,
          value: hash[:value],
          value_quantity: (type == "BP" ? nil : hash[:value]),
          unit: stated_vital_unit(hash, mapping),
          category: "vital-signs",
          status: "final",
          effective_datetime: hash[:recorded_date]
        }
      end

      # Recorded text when the row states it. A blank (or absent) units
      # field is not a unit; the map's UCUM unit is the fallback. The
      # recorded text is display-only — it never becomes valueQuantity.code.
      def self.stated_vital_unit(hash, mapping)
        recorded = if hash.key?(:units)
          hash[:units]
        elsif hash.key?("units")
          hash["units"]
        end
        recorded.presence || mapping&.dig(:unit)
      end

      def self.vital_id(patient_dfn, hash)
        id = "vital-#{patient_dfn}-#{hash[:type].to_s.downcase}"
        recorded = hash[:recorded_date]
        id += "-#{recorded.strftime('%Y%m%d%H%M')}" if recorded.respond_to?(:strftime)
        id
      end
      private_class_method :vital_from_hash, :vital_attributes, :stated_vital_unit, :vital_id

      def vital_sign? = category == "vital-signs"
      def laboratory? = category == "laboratory"
      def sdoh? = category == "social-history" || category == "survey"

      def to_fhir
        if blood_pressure? && numeric_blood_pressure?
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
          effectiveDateTime: effective_datetime&.iso8601,
          valueQuantity: build_value_quantity,
          valueString: fhir_value_string,
          category: category ? [ { coding: [ { code: category, system: CATEGORY_SYSTEM } ] } ] : nil
        }.compact
      end

      def build_blood_pressure_fhir
        systolic_text, diastolic_text = blood_pressure_parts
        {
          resourceType: "Observation",
          id: ien&.to_s,
          meta: build_meta,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          code: build_code,
          effectiveDateTime: effective_datetime&.iso8601,
          category: category ? [ { coding: [ { code: category, system: CATEGORY_SYSTEM } ] } ] : nil,
          component: [
            blood_pressure_component(VITAL_SIGNS_CODES[:systolic], systolic_text),
            blood_pressure_component(VITAL_SIGNS_CODES[:diastolic], diastolic_text)
          ]
        }.compact
      end

      def blood_pressure_component(component_code, text)
        {
          code: { coding: [ { code: component_code, system: "http://loinc.org" } ] },
          valueQuantity: quantity_hash(quantity_number(text))
        }
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

      # Survey-category observations (screening instrument totals, SDOH
      # screeners) claim the US Core screening-assessment profile regardless of
      # which instrument produced them, so no per-instrument code list has to be
      # maintained here.
      def build_meta
        return { profile: [ SdohObservation::US_CORE_SCREENING_PROFILE ] } if category == "survey"

        profile_url = US_CORE_PROFILES[code]
        profile_url ? { profile: [ profile_url ] } : nil
      end

      # Quantity.value is a FHIR decimal — a JSON number, never a string.
      # A non-numeric vital is not a quantity; fhir_value_string carries
      # the recorded text instead.
      def build_value_quantity
        number = quantity_number(value_quantity)
        return if number.nil?

        quantity_hash(number)
      end

      # code and system come from the UCUM map only when the recorded unit
      # is blank or equals that map unit. Other recorded text is the unit
      # alone — never a code that disagrees with it ("Celsius" must not
      # carry [degF]). A blank recorded unit with a map unit takes unit,
      # code, and system from the map. A survey score has no vital mapping;
      # its unit attribute is already the UCUM code ("{score}"), so unit,
      # code, and system are that same text. Omit all three when both the
      # recorded text and the map are blank.
      def quantity_hash(number)
        recorded = unit.presence
        mapped = mapped_ucum_unit
        fields = { value: number }

        if mapped && (recorded.nil? || recorded == mapped)
          fields[:unit] = mapped
          fields[:code] = mapped
          fields[:system] = UCUM_SYSTEM
        elsif recorded
          fields[:unit] = recorded
          if mapped.nil? && !vital_sign?
            fields[:code] = recorded
            fields[:system] = UCUM_SYSTEM
          end
        end

        fields
      end

      def mapped_ucum_unit
        VITAL_TYPE_MAP.each_value.find { |mapping| mapping[:code] == code }&.dig(:unit).presence
      end

      def fhir_value_string
        return value if sdoh? && value_quantity.blank?
        return value if vital_sign? && value.present? && quantity_number(value_quantity).nil?

        nil
      end

      def numeric_blood_pressure?
        parts = blood_pressure_parts
        parts.length == 2 && parts.all? { |part| !quantity_number(part).nil? }
      end

      def blood_pressure_parts
        value.to_s.split("/", 2).map(&:strip)
      end

      def quantity_number(text)
        return if text.blank?

        Float(text)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
