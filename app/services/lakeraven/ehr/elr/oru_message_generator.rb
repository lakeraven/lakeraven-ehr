# frozen_string_literal: true

# Elr::OruMessageGenerator -- Generate HL7 v2.5.1 ORU^R01 messages
#
# ONC criteria: 170.315(f)(3) -- Electronic Laboratory Reporting
#
# Message structure:
#   MSH -- Message Header
#   PID -- Patient Identification
#   OBR -- Observation Request (order info)
#   OBX -- Observation Result (lab value + LOINC)
#   OBX -- Organism identification (SNOMED, if applicable)
#   SPM -- Specimen

module Lakeraven
  module EHR
    module Elr
      class OruMessageGenerator
        FIELD_SEP = "|"
        COMPONENT_SEP = "^"
        HL7_VERSION = "2.5.1"
        ENCODING_CHARS = "^~\\&"
        LOINC_SYSTEM = "LN"
        SNOMED_SYSTEM = "SCT"

        def self.generate(observation:, patient:, ordering_provider:, performing_lab:, specimen: nil, organism: nil)
          new(
            observation: observation,
            patient: patient,
            ordering_provider: ordering_provider,
            performing_lab: performing_lab,
            specimen: specimen,
            organism: organism
          ).build
        end

        def initialize(observation:, patient:, ordering_provider:, performing_lab:, specimen: nil, organism: nil)
          @observation = observation
          @patient = patient
          @ordering_provider = ordering_provider
          @performing_lab = performing_lab
          @specimen = specimen
          @organism = organism
        end

        def build
          segs = []
          segs << build_msh
          segs << build_pid
          segs << build_obr
          segs << build_obx_result
          segs << build_obx_organism if @organism
          segs << build_spm if @specimen
          segs.join("\r") + "\r"
        end

        private

        def build_msh
          fields = [
            "MSH",
            ENCODING_CHARS,
            @performing_lab[:name] || "Sending Lab",
            @performing_lab[:clia] || "",
            "NYSDOH",
            "ECLRS",
            Time.current.strftime("%Y%m%d%H%M%S"),
            "",
            "ORU#{COMPONENT_SEP}R01#{COMPONENT_SEP}ORU_R01",
            SecureRandom.uuid,
            "P",
            HL7_VERSION
          ]
          fields.join(FIELD_SEP)
        end

        def build_pid
          dob = @patient[:dob].to_s.delete("-") if @patient[:dob]
          addr = @patient[:address] || {}
          address = [
            hl7_escape(addr[:street]),
            nil,
            hl7_escape(addr[:city]),
            hl7_escape(addr[:state]),
            hl7_escape(addr[:zip])
          ].join(COMPONENT_SEP)

          name = [
            hl7_escape(@patient.dig(:name, :family)),
            hl7_escape(@patient.dig(:name, :given))
          ].join(COMPONENT_SEP)

          fields = [
            "PID",
            "1",
            "",
            @patient[:dfn],
            "",
            name,
            "",
            dob || "",
            @patient[:sex] || ""
          ]
          fields += [ "", "", address ]
          fields.join(FIELD_SEP)
        end

        def build_obr
          fields = [
            "OBR",
            "1", "", "",
            loinc_coded(@observation.code, @observation.display),
            "", "",
            format_datetime(@observation.effective_datetime),
            "", "", "", "", "", "", "",
            provider_coded(@ordering_provider),
            "", "", "", "", "",
            format_datetime(@observation.effective_datetime),
            "", "",
            observation_status
          ]
          fields.join(FIELD_SEP)
        end

        def build_obx_result
          fields = [
            "OBX",
            "1",
            value_type,
            loinc_coded(@observation.code, @observation.display),
            "",
            obx_value,
            unit_coded,
            "",
            "",
            "",
            "",
            observation_status
          ]
          fields.join(FIELD_SEP)
        end

        def build_obx_organism
          fields = [
            "OBX",
            "2",
            "CWE",
            loinc_coded("6463-4", "Bacteria identified"),
            "",
            snomed_coded(@organism[:code], @organism[:display]),
            "", "", "", "", "",
            "F"
          ]
          fields.join(FIELD_SEP)
        end

        def build_spm
          spec = @specimen || {}
          fields = [
            "SPM",
            "1", "", "",
            specimen_type_coded(spec),
            "", "", "", "", "", "", "", "", "", "", "",
            format_datetime(spec[:collected_at])
          ]
          fields.join(FIELD_SEP)
        end

        # --- Helpers ---

        def hl7_escape(str)
          return "" if str.blank?

          str.to_s
            .gsub("\\", "\\E\\")
            .gsub("|", "\\F\\")
            .gsub("^", "\\S\\")
            .gsub("&", "\\T\\")
            .gsub("~", "\\R\\")
        end

        def loinc_coded(code, display)
          "#{hl7_escape(code)}#{COMPONENT_SEP}#{hl7_escape(display)}#{COMPONENT_SEP}#{LOINC_SYSTEM}"
        end

        def snomed_coded(code, display)
          "#{hl7_escape(code)}#{COMPONENT_SEP}#{hl7_escape(display)}#{COMPONENT_SEP}#{SNOMED_SYSTEM}"
        end

        def provider_coded(provider)
          "#{hl7_escape(provider[:npi])}#{COMPONENT_SEP}#{hl7_escape(provider[:name])}"
        end

        def specimen_type_coded(spec)
          "#{hl7_escape(spec[:type])}#{COMPONENT_SEP}#{hl7_escape(spec[:type_display])}"
        end

        def format_datetime(dt)
          return "" if dt.blank?

          dt.strftime("%Y%m%d%H%M%S")
        end

        def numeric_result?
          @observation.value_quantity.present? &&
            @observation.value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
        end

        def value_type
          numeric_result? ? "NM" : "ST"
        end

        def obx_value
          if numeric_result?
            @observation.value_quantity.to_s
          else
            hl7_escape(@observation.value)
          end
        end

        def unit_coded
          return "" if @observation.unit.blank?

          "#{@observation.unit}#{COMPONENT_SEP}#{@observation.unit}#{COMPONENT_SEP}UCUM"
        end

        def observation_status
          case @observation.status
          when "final" then "F"
          when "preliminary" then "P"
          when "corrected", "amended" then "C"
          else "F"
          end
        end
      end
    end
  end
end
