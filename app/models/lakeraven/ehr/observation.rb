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

      # RPMS measurement/vital type mnemonics → LOINC. Terminology mapping
      # only — NO units here: units come from the source system
      # (BEHOVM2 VUNITS via the rpms-rpc Measurement read); a value whose
      # source supplies no unit is dropped, never guessed (Vardana §5.1).
      # Both AUTTMSR abbreviations (BGOVMSR: "HT;WT;TMP;BP;PU;RS;PA") and
      # the GMRV-style codes ORQQVI uses ("BP;HT;WT;T;R;P;PN") appear.
      VITAL_TYPE_MAP = {
        "BP"  => { code: "85354-9", display: "Blood Pressure" },
        "P"   => { code: "8867-4",  display: "Heart Rate" },
        "PU"  => { code: "8867-4",  display: "Heart Rate" },
        "T"   => { code: "8310-5",  display: "Body Temperature" },
        "TMP" => { code: "8310-5",  display: "Body Temperature" },
        "R"   => { code: "9279-1",  display: "Respiratory Rate" },
        "RS"  => { code: "9279-1",  display: "Respiratory Rate" },
        "POX" => { code: "2708-6",  display: "Oxygen Saturation" },
        "O2"  => { code: "2708-6",  display: "Oxygen Saturation" },
        "WT"  => { code: "29463-7", display: "Body Weight" },
        "HT"  => { code: "8302-2",  display: "Body Height" },
        "BMI" => { code: "39156-5", display: "BMI" }
      }.freeze

      # Source display unit → UCUM code. Pure code-system translation of a
      # unit the SOURCE supplied; an untranslatable source unit is carried
      # as display text without a UCUM code/system claim.
      UCUM_UNITS = {
        "lb" => "[lb_av]", "lbs" => "[lb_av]", "[lb_av]" => "[lb_av]",
        "in" => "[in_i]", "[in_i]" => "[in_i]",
        "f" => "[degF]", "[degf]" => "[degF]",
        "c" => "Cel", "cel" => "Cel",
        "mmhg" => "mm[Hg]", "mm[hg]" => "mm[Hg]",
        "kg" => "kg", "cm" => "cm", "%" => "%",
        "/min" => "/min", "bpm" => "/min", "kg/m2" => "kg/m2"
      }.freeze

      # FHIR R4 Observation.status — REQUIRED binding.
      VALID_STATUSES = %w[
        registered preliminary final amended corrected cancelled
        entered-in-error unknown
      ].freeze

      # Systolic/diastolic shape a BP value must have to be serialized;
      # anything else (garbage text, a lone number) is dropped rather than
      # emitted as components with fabricated 0.0 values.
      BP_VALUE_PATTERN = %r{\A\d+(\.\d+)?\s*/\s*\d+(\.\d+)?\z}

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
      # Provenance context — how the value entered the record. RPMS/PCC keeps
      # this on the measurement's parent VISIT (file 9000010): SERVICE
      # CATEGORY, field .07 ("A"=ambulatory ... "T"=telecommunications,
      # "E"=event/historical, "C"=chart review). See
      # FHIR::ObservationProvenanceSerializer for the FHIR mapping.
      attribute :service_category, :string
      attribute :visit_ien, :string
      # Encounter provider name when the measurement read supplies one
      # (BGOVMSR GET reply piece 6) — display only, never an invented id.
      attribute :provider_name, :string

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

      # Build Observation instances from decorated measurement rows as the
      # rpms-rpc Measurement reads return them (.history / .for_visit /
      # .latest / .find):
      #
      #   { measurement_ien:, type:, value:, units:, date:, visit_ien:,
      #     service_category:, capture_mode:, entered_in_error:, ... }
      #
      # Honest-serialization rules (Vardana §5):
      #   * id is the real V MEASUREMENT IEN — a row without one has no
      #     stable identity and is dropped (never a blank or colliding id).
      #   * units come from the source (BEHOVM2 VUNITS); a row without a
      #     source unit is DROPPED, not guessed from the type.
      #   * a BP value that isn't systolic/diastolic is dropped, not
      #     serialized as 0.0 components.
      #   * status reflects the wire ENTERED IN ERROR flag; when the flag
      #     could not be read the status is "unknown", never invented.
      def self.from_measurement_hashes(hashes, patient_dfn:)
        hashes.filter_map do |h|
          mapping = VITAL_TYPE_MAP[h[:type].to_s]
          next unless mapping

          ien = h[:measurement_ien].to_s.strip
          next if ien.empty?

          unit = translate_unit(h[:units])
          next if unit.nil?

          value = h[:value].to_s
          blood_pressure = mapping[:code] == VITAL_SIGNS_CODES[:blood_pressure]
          next if blood_pressure && !BP_VALUE_PATTERN.match?(value)

          new(
            ien: ien,
            patient_dfn: patient_dfn,
            code: mapping[:code],
            code_system: "loinc",
            display: mapping[:display],
            value: value,
            value_quantity: blood_pressure ? nil : value,
            unit: unit,
            category: "vital-signs",
            status: status_from_wire(h[:entered_in_error]),
            effective_datetime: h[:date],
            service_category: h[:service_category],
            visit_ien: h[:visit_ien]&.to_s,
            provider_name: h[:provider_name]
          )
        end
      end

      # Wire ENTERED IN ERROR (#9000010.01 field 2) → FHIR status.
      # nil means the flag could not be read — reported honestly as
      # "unknown", never guessed to "final".
      def self.status_from_wire(entered_in_error)
        case entered_in_error
        when true then "entered-in-error"
        when false then "final"
        else "unknown"
        end
      end

      # Source unit string → the unit to serialize (UCUM code when the
      # source unit translates, else the raw source text). nil when the
      # source supplied no unit — the caller drops the row (§5.1).
      def self.translate_unit(raw)
        text = raw.to_s.strip
        return nil if text.empty?

        UCUM_UNITS.fetch(text.downcase, text)
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
          effectiveDateTime: effective_datetime&.iso8601,
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
          effectiveDateTime: effective_datetime&.iso8601,
          category: category ? [ { coding: [ { code: category, system: CATEGORY_SYSTEM } ] } ] : nil,
          component: [
            bp_component(VITAL_SIGNS_CODES[:systolic], systolic_val),
            bp_component(VITAL_SIGNS_CODES[:diastolic], diastolic_val)
          ]
        }.compact
      end

      def bp_component(loinc_code, raw_value)
        {
          code: { coding: [ { code: loinc_code, system: "http://loinc.org" } ] },
          valueQuantity: quantity_for(raw_value.to_f)
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

      def build_meta
        profile_url = US_CORE_PROFILES[code]
        profile_url ? { profile: [ profile_url ] } : nil
      end

      # Quantity.value is a FHIR decimal — it must serialize as a JSON
      # number, never a string. Non-numeric values fall back to nil (the
      # caller compacts the element away) rather than emitting invalid JSON.
      def build_value_quantity
        return nil unless value_quantity

        numeric = begin
          Float(value_quantity)
        rescue ArgumentError, TypeError
          return nil
        end

        quantity_for(numeric)
      end

      # UCUM `code`/`system` are asserted only when the (source-supplied)
      # unit is a known UCUM code; otherwise the unit rides as display
      # text alone — a display unit is never passed off as UCUM.
      def quantity_for(numeric)
        qty = { value: numeric }
        if unit
          qty[:unit] = unit
          if UCUM_UNITS.value?(unit)
            qty[:code] = unit
            qty[:system] = "http://unitsofmeasure.org"
          end
        end
        qty
      end
    end
  end
end
