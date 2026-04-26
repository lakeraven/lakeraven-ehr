# frozen_string_literal: true

module Lakeraven
  module EHR
    # CcdaGenerator - Generate C-CDA (Consolidated Clinical Document Architecture) XML
    # ONC 170.315(b)(1) - Transitions of Care (send path)
    # Ported from rpms_redux CcdaGenerator.
    class CcdaGenerator
      NS = "urn:hl7-org:v3"
      XSI = "http://www.w3.org/2001/XMLSchema-instance"

      LOINC_OID    = "2.16.840.1.113883.6.1"
      RXNORM_OID   = "2.16.840.1.113883.6.88"
      ICD10_OID    = "2.16.840.1.113883.6.90"
      SNOMED_OID   = "2.16.840.1.113883.6.96"
      CPT_OID      = "2.16.840.1.113883.6.12"

      def self.generate(patient:, allergies: [], conditions: [], medications: [], vitals: [], encounters: [], author: {})
        new(patient:, allergies:, conditions:, medications:, vitals:, encounters:, author:).build
      end

      def initialize(patient:, allergies:, conditions:, medications:, vitals:, encounters:, author:)
        @patient = patient
        @allergies = allergies || []
        @conditions = conditions || []
        @medications = medications || []
        @vitals = vitals || []
        @encounters = encounters || []
        @author = author || {}
      end

      def build
        builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
          xml.ClinicalDocument("xmlns" => NS, "xmlns:xsi" => XSI) do
            build_header(xml)
            build_record_target(xml)
            build_author(xml)
            build_custodian(xml)
            xml.component do
              xml.structuredBody do
                build_allergies_section(xml)
                build_problems_section(xml)
                build_medications_section(xml)
                build_vitals_section(xml)
                build_encounters_section(xml)
              end
            end
          end
        end
        builder.to_xml
      end

      private

      def build_header(xml)
        xml.typeId(root: "2.16.840.1.113883.1.3", extension: "POCD_HD000040")
        xml.templateId(root: "2.16.840.1.113883.10.20.22.1.2")
        xml.id(root: "2.16.840.1.113883.19.5.99999.1", extension: SecureRandom.uuid)
        xml.code(code: "34133-9", codeSystem: LOINC_OID, displayName: "Summarization of Episode Note")
        xml.title("Continuity of Care Document")
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
              if @patient[:dob]
                xml.birthTime(value: @patient[:dob].to_s.delete("-"))
              end
            end
          end
        end
      end

      def build_author(xml)
        xml.author do
          xml.time(value: Time.current.strftime("%Y%m%d%H%M%S"))
          xml.assignedAuthor do
            xml.id(root: "2.16.840.1.113883.19.5", extension: "provider")
            if @author[:name]
              xml.assignedPerson do
                xml.name { xml.text(@author[:name]) }
              end
            end
            if @author[:institution]
              xml.representedOrganization do
                xml.name(@author[:institution])
              end
            end
          end
        end
      end

      def build_custodian(xml)
        xml.custodian do
          xml.assignedCustodian do
            xml.representedCustodianOrganization do
              xml.id(root: "2.16.840.1.113883.19.5")
              xml.name(@author[:institution] || "Healthcare Facility")
            end
          end
        end
      end

      def build_allergies_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.6.1")
            xml.code(code: "48765-2", codeSystem: LOINC_OID, displayName: "Allergies")
            xml.title("Allergies and Adverse Reactions")
            @allergies.each do |allergy|
              xml.entry do
                xml.act(classCode: "ACT", moodCode: "EVN") do
                  xml.templateId(root: "2.16.840.1.113883.10.20.22.4.30")
                  xml.entryRelationship(typeCode: "SUBJ") do
                    xml.observation(classCode: "OBS", moodCode: "EVN") do
                      xml.templateId(root: "2.16.840.1.113883.10.20.22.4.7")
                      xml.participant(typeCode: "CSM") do
                        xml.participantRole(classCode: "MANU") do
                          xml.playingEntity(classCode: "MMAT") do
                            xml.code(
                              code: allergy[:code],
                              codeSystem: allergy[:code_system] || RXNORM_OID,
                              codeSystemName: code_system_name(allergy[:code_system]),
                              displayName: allergy[:display]
                            )
                            xml.name(allergy[:display])
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      def build_problems_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.5.1")
            xml.code(code: "11450-4", codeSystem: LOINC_OID, displayName: "Problem List")
            xml.title("Problems")
            @conditions.each do |condition|
              xml.entry do
                xml.act(classCode: "ACT", moodCode: "EVN") do
                  xml.templateId(root: "2.16.840.1.113883.10.20.22.4.3")
                  xml.entryRelationship(typeCode: "SUBJ") do
                    xml.observation(classCode: "OBS", moodCode: "EVN") do
                      xml.templateId(root: "2.16.840.1.113883.10.20.22.4.4")
                      xml.value(
                        "xsi:type" => "CD",
                        code: condition[:code],
                        codeSystem: condition[:code_system] || ICD10_OID,
                        codeSystemName: code_system_name(condition[:code_system]),
                        displayName: condition[:display]
                      )
                    end
                  end
                end
              end
            end
          end
        end
      end

      def build_medications_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.1.1")
            xml.code(code: "10160-0", codeSystem: LOINC_OID, displayName: "Medications")
            xml.title("Medications")
            @medications.each do |med|
              xml.entry do
                xml.substanceAdministration(classCode: "SBADM", moodCode: "EVN") do
                  xml.templateId(root: "2.16.840.1.113883.10.20.22.4.16")
                  xml.consumable do
                    xml.manufacturedProduct(classCode: "MANU") do
                      xml.templateId(root: "2.16.840.1.113883.10.20.22.4.23")
                      xml.manufacturedMaterial do
                        xml.code(
                          code: med[:code],
                          codeSystem: med[:code_system] || RXNORM_OID,
                          codeSystemName: code_system_name(med[:code_system]),
                          displayName: med[:display]
                        )
                        xml.name(med[:display])
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      def build_vitals_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.4.1")
            xml.code(code: "8716-3", codeSystem: LOINC_OID, displayName: "Vital Signs")
            xml.title("Vital Signs")
            @vitals.each do |vital|
              xml.entry do
                xml.organizer(classCode: "CLUSTER", moodCode: "EVN") do
                  xml.templateId(root: "2.16.840.1.113883.10.20.22.4.26")
                  xml.component do
                    xml.observation(classCode: "OBS", moodCode: "EVN") do
                      xml.templateId(root: "2.16.840.1.113883.10.20.22.4.27")
                      xml.code(code: vital[:code], codeSystem: LOINC_OID, displayName: vital[:display])
                      xml.effectiveTime(value: vital[:date]&.to_s&.delete("-")) if vital[:date]
                      xml.value("xsi:type" => "PQ", value: vital[:value], unit: vital[:units])
                    end
                  end
                end
              end
            end
          end
        end
      end

      def build_encounters_section(xml)
        xml.component do
          xml.section do
            xml.templateId(root: "2.16.840.1.113883.10.20.22.2.22.1")
            xml.code(code: "46240-8", codeSystem: LOINC_OID, displayName: "Encounters")
            xml.title("Encounters")
            @encounters.each do |enc|
              xml.entry do
                xml.encounter(classCode: "ENC", moodCode: "EVN") do
                  xml.templateId(root: "2.16.840.1.113883.10.20.22.4.49")
                  xml.code(code: enc[:type_code], codeSystem: CPT_OID, displayName: enc[:type_display]) if enc[:type_code]
                  xml.effectiveTime(value: enc[:date]&.to_s&.delete("-")) if enc[:date]
                  if enc[:performer]
                    xml.performer do
                      xml.assignedEntity do
                        xml.assignedPerson do
                          xml.name { xml.text(enc[:performer]) }
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      def code_system_name(oid)
        case oid
        when RXNORM_OID then "RxNorm"
        when ICD10_OID then "ICD-10-CM"
        when SNOMED_OID then "SNOMED CT"
        when LOINC_OID then "LOINC"
        when CPT_OID then "CPT"
        else "Unknown"
        end
      end
    end

    # CcdaParser - Minimal parser for C-CDA round-trip testing
    class CcdaParser
      NS = "urn:hl7-org:v3"

      def self.parse(xml)
        new.parse(xml)
      end

      def parse(xml)
        doc = Nokogiri::XML(xml)
        {
          allergies: parse_allergies(doc),
          conditions: parse_conditions(doc),
          medications: parse_medications(doc)
        }
      end

      private

      def parse_allergies(doc)
        doc.xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.6.1']]//xmlns:entry",
          "xmlns" => NS
        ).map do |entry|
          code_node = entry.at_xpath(".//xmlns:playingEntity/xmlns:code", "xmlns" => NS)
          {
            allergen_code: code_node&.attr("code"),
            allergen_display: code_node&.attr("displayName")
          }
        end
      end

      def parse_conditions(doc)
        doc.xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.5.1']]//xmlns:entry",
          "xmlns" => NS
        ).map do |entry|
          value_node = entry.at_xpath(".//xmlns:observation/xmlns:value", "xmlns" => NS)
          {
            code: value_node&.attr("code"),
            display: value_node&.attr("displayName")
          }
        end
      end

      def parse_medications(doc)
        doc.xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.1.1']]//xmlns:entry",
          "xmlns" => NS
        ).map do |entry|
          code_node = entry.at_xpath(".//xmlns:manufacturedMaterial/xmlns:code", "xmlns" => NS)
          {
            code: code_node&.attr("code"),
            display: code_node&.attr("displayName")
          }
        end
      end
    end
  end
end
