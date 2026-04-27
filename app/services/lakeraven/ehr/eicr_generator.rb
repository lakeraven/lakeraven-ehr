# frozen_string_literal: true

module Lakeraven
  module EHR
    # EicrGenerator -- Generate eICR (electronic Initial Case Report) CDA documents
    #
    # ONC 170.315(f)(5) -- Electronic Case Reporting
    #
    # Produces eICR CDA documents per HL7 CDA R2 eCR Implementation Guide.
    # Template ID: 2.16.840.1.113883.10.20.15.2 (Public Health Case Report)
    class EicrGenerator
      NS = "urn:hl7-org:v3"
      XSI = "http://www.w3.org/2001/XMLSchema-instance"
      EICR_TEMPLATE_ID = "2.16.840.1.113883.10.20.15.2"
      ICD10_OID = "2.16.840.1.113883.6.90"
      LOINC_OID = "2.16.840.1.113883.6.1"
      SNOMED_OID = "2.16.840.1.113883.6.96"

      def self.generate(condition:, patient:, encounter:, provider:)
        new(condition: condition, patient: patient, encounter: encounter, provider: provider).build
      end

      def initialize(condition:, patient:, encounter:, provider:)
        @condition = condition
        @patient = patient
        @encounter = encounter
        @provider = provider
      end

      def build
        builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
          xml.ClinicalDocument("xmlns" => NS, "xmlns:xsi" => XSI) do
            build_header(xml)
            build_record_target(xml)
            build_author(xml)
            build_custodian(xml)
            build_encompassing_encounter(xml)
            xml.component do
              xml.structuredBody do
                build_reason_for_visit(xml)
                build_encounters_section(xml)
                build_reportable_condition_section(xml)
              end
            end
          end
        end
        builder.to_xml
      end

      private

      def build_header(xml)
        xml.typeId(root: "2.16.840.1.113883.1.3", extension: "POCD_HD000040")
        xml.templateId(root: EICR_TEMPLATE_ID)
        xml.templateId(root: "2.16.840.1.113883.10.20.22.1.1")
        xml.id(root: "2.16.840.1.113883.19.5.99999.1", extension: SecureRandom.uuid)
        xml.code(code: "55751-2", codeSystem: LOINC_OID, displayName: "Public Health Case Report")
        xml.title("Initial Public Health Case Report - eICR")
        xml.effectiveTime(value: Time.current.strftime("%Y%m%d%H%M%S"))
        xml.confidentialityCode(code: "N", codeSystem: "2.16.840.1.113883.5.25")
        xml.languageCode(code: "en-US")
      end

      def build_record_target(xml)
        xml.recordTarget do
          xml.patientRole do
            xml.id(extension: @patient[:dfn])
            if @patient[:address]
              xml.addr do
                xml.streetAddressLine(@patient[:address][:street]) if @patient[:address][:street]
                xml.city(@patient[:address][:city]) if @patient[:address][:city]
                xml.state(@patient[:address][:state]) if @patient[:address][:state]
                xml.postalCode(@patient[:address][:zip]) if @patient[:address][:zip]
              end
            end
            xml.patient do
              xml.name do
                xml.given(@patient.dig(:name, :given))
                xml.family(@patient.dig(:name, :family))
              end
              xml.administrativeGenderCode(code: @patient[:sex]) if @patient[:sex]
              xml.birthTime(value: @patient[:dob].to_s.delete("-")) if @patient[:dob]
            end
          end
        end
      end

      def build_author(xml)
        xml.author do
          xml.time(value: Time.current.strftime("%Y%m%d%H%M%S"))
          xml.assignedAuthor do
            xml.id(root: "2.16.840.1.113883.4.6", extension: @provider[:npi] || "unknown")
            xml.assignedPerson do
              xml.name { xml.text(@provider[:name]) }
            end
          end
        end
      end

      def build_custodian(xml)
        xml.custodian do
          xml.assignedCustodian do
            xml.representedCustodianOrganization do
              xml.id(root: "2.16.840.1.113883.19.5")
              xml.name(@encounter[:facility] || "Healthcare Facility")
            end
          end
        end
      end

      def build_encompassing_encounter(xml)
        xml.componentOf do
          xml.encompassingEncounter do
            xml.id(root: SecureRandom.uuid)
            xml.code(code: @encounter[:type_code], displayName: @encounter[:type_display]) if @encounter[:type_code]
            xml.effectiveTime do
              xml.low(value: @encounter[:date].to_s.delete("-")) if @encounter[:date]
            end
            xml.location do
              xml.healthCareFacility do
                xml.location do
                  xml.name(@encounter[:facility] || "Healthcare Facility")
                end
              end
            end
          end
        end
      end

      def build_reason_for_visit(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.12")
            xml.code(code: "29299-5", codeSystem: LOINC_OID, displayName: "Reason for visit")
            xml.title("Reason for Visit")
            xml.text_ condition_display
          end
        end
      end

      def build_encounters_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.22.1")
            xml.code(code: "46240-8", codeSystem: LOINC_OID, displayName: "Encounters")
            xml.title("Encounters")
            xml.entry do
              xml.encounter(classCode: "ENC", moodCode: "EVN") do
                xml.templateId(root: "2.16.840.1.113883.10.20.22.4.49")
                xml.effectiveTime(value: @encounter[:date].to_s.delete("-")) if @encounter[:date]
              end
            end
          end
        end
      end

      def build_reportable_condition_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.15.2.3.2")
            xml.code(code: "55752-0", codeSystem: LOINC_OID, displayName: "Clinical information")
            xml.title("Reportable Condition")
            xml.entry do
              xml.observation(classCode: "OBS", moodCode: "EVN") do
                xml.code(code: "64572001", codeSystem: SNOMED_OID, displayName: "Condition")
                xml.value(
                  "xsi:type" => "CD",
                  code: condition_code,
                  codeSystem: condition_code_system_oid,
                  displayName: condition_display
                )
              end
            end
          end
        end
      end

      def condition_code
        @condition.respond_to?(:code) ? @condition.code : @condition[:code]
      end

      def condition_display
        @condition.respond_to?(:display) ? @condition.display : @condition[:display]
      end

      def condition_code_system_oid
        system = @condition.respond_to?(:code_system) ? @condition.code_system : @condition[:code_system]
        system == "snomed" ? SNOMED_OID : ICD10_OID
      end
    end
  end
end
