# frozen_string_literal: true

module Lakeraven
  module EHR
    # CcdaGenerator - Generate C-CDA (Consolidated Clinical Document Architecture) XML
    # ONC 170.315(b)(1) - Transitions of Care (send path)
    # Ported from the predecessor app CcdaGenerator.
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

      # Patient and the clinical rows are model objects. A Hash used to be
      # read with `[:key]`; that fallback is gone, and a Hash raises here,
      # before any XML is built. The author stays a hash — it is the
      # attestation the controller assembled, not a chart row.
      def initialize(patient:, allergies:, conditions:, medications:, vitals:, encounters:, author:)
        reject_hash_input!(patient, allergies, conditions, medications, vitals, encounters)
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
        family, given = patient_name_parts
        xml.recordTarget do
          xml.patientRole do
            xml.id(extension: @patient.dfn.to_s)
            build_patient_address(xml)
            xml.patient do
              xml.name do
                xml.given(given)
                xml.family(family)
              end
              xml.administrativeGenderCode(code: @patient.sex) if @patient.sex
              xml.birthTime(value: hl7_date(@patient.dob)) if @patient.dob
            end
          end
        end
      end

      # Patient#name is "FAMILY,GIVEN" (VistA). The document still carries
      # the two parts in separate elements.
      def patient_name_parts
        return [ nil, nil ] if @patient.name.blank?

        family, given = @patient.name.split(",", 2)
        [ family&.strip, given&.strip ]
      end

      def build_patient_address(xml)
        xml.addr do
          xml.streetAddressLine(@patient.address_line1) if @patient.address_line1
          xml.city(@patient.city) if @patient.city
          xml.state(@patient.state) if @patient.state
          xml.postalCode(@patient.zip_code) if @patient.zip_code
        end
      end

      # WHO authored this document.
      #
      # `assignedAuthor` must carry either an `assignedPerson` or an
      # `assignedAuthoringDevice` — one with neither is C-CDA-invalid, and that
      # is what this emitted whenever no display name was supplied, while still
      # asserting a hardcoded `extension="provider"` id. So the degraded state
      # was not honest-but-empty, it was a silent false attestation.
      #
      # Now: a human author is identified by DUZ (and NPI where known) and gets
      # an assignedPerson; with no human, the document says so explicitly with
      # an assignedAuthoringDevice naming the client that generated it.
      def build_author(xml)
        xml.author do
          xml.time(value: Time.current.strftime("%Y%m%d%H%M%S"))
          xml.assignedAuthor do
            build_author_id(xml)
            if @author[:name].present?
              xml.assignedPerson { xml.name { xml.text(@author[:name]) } }
            else
              xml.assignedAuthoringDevice do
                xml.softwareName(@author[:device].presence || "Lakeraven EHR")
              end
            end
            if @author[:institution]
              xml.representedOrganization { xml.name(@author[:institution]) }
            end
          end
        end
      end

      # NPI when we have one, else the DUZ in the local provider namespace,
      # else the authoring system. Never a hardcoded "provider".
      def build_author_id(xml)
        if @author[:npi].present?
          xml.id(root: "2.16.840.1.113883.4.6", extension: @author[:npi])
        elsif @author[:duz].present?
          xml.id(root: "2.16.840.1.113883.19.5", extension: @author[:duz].to_s)
        else
          xml.id(root: "2.16.840.1.113883.19.5", nullFlavor: "NA")
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
                              code: allergy.allergen_code,
                              codeSystem: RXNORM_OID,
                              codeSystemName: code_system_name(RXNORM_OID),
                              displayName: allergy.allergen
                            )
                            xml.name(allergy.allergen)
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
                        code: condition.code,
                        codeSystem: condition_code_system_oid(condition),
                        codeSystemName: condition_code_system_name(condition),
                        displayName: condition.display
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
                          code: med.medication_code,
                          codeSystem: RXNORM_OID,
                          codeSystemName: code_system_name(RXNORM_OID),
                          displayName: med.medication_display
                        )
                        xml.name(med.medication_display)
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
                      xml.code(code: vital.code, codeSystem: LOINC_OID, displayName: vital.display)
                      xml.effectiveTime(value: hl7_timestamp(vital.effective_datetime)) if vital.effective_datetime
                      xml.value("xsi:type" => "PQ", value: vital.value, unit: vital.unit)
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
            xml.title("Encounters")
            @encounters.each do |enc|
              xml.entry do
                xml.encounter(classCode: "ENC", moodCode: "EVN") do
                  xml.templateId(root: "2.16.840.1.113883.10.20.22.4.49")
                  xml.code(code: enc.type_code, codeSystem: CPT_OID, displayName: enc.type_display) if enc.type_code
                  xml.effectiveTime(value: hl7_timestamp(enc.period_start)) if enc.period_start
                  build_encounter_performer(xml, enc)
                end
              end
            end
            xml.code(code: "46240-8", codeSystem: LOINC_OID, displayName: "Encounters")
          end
        end
      end

      def build_encounter_performer(xml, enc)
        return if enc.practitioner_identifier.blank?

        xml.performer do
          xml.assignedEntity do
            xml.assignedPerson do
              xml.name { xml.text_ enc.practitioner_identifier }
            end
          end
        end
      end

      # AllergyIntolerance and MedicationRequest have no code-system
      # attribute; both are RxNorm, which is the OID those sections
      # already emitted. Condition#code_system is "icd10" or "snomed".
      def condition_code_system_oid(condition)
        system = condition.code_system
        return ICD10_OID if system.blank?

        case system
        when "icd10" then ICD10_OID
        when "snomed" then SNOMED_OID
        else system
        end
      end

      def condition_code_system_name(condition)
        return code_system_name(nil) if condition.code_system.blank?

        code_system_name(condition_code_system_oid(condition))
      end

      def hl7_date(value)
        value.strftime("%Y%m%d")
      end

      def hl7_timestamp(value)
        value.strftime("%Y%m%d%H%M%S")
      end

      def reject_hash_input!(patient, allergies, conditions, medications, vitals, encounters)
        raise ArgumentError, hash_input_message("patient") if patient.is_a?(Hash)

        {
          allergies: allergies,
          conditions: conditions,
          medications: medications,
          vitals: vitals,
          encounters: encounters
        }.each do |name, rows|
          reject_hash_rows!(rows, name)
        end
      end

      def reject_hash_rows!(rows, name)
        return if rows.nil?
        raise ArgumentError, hash_input_message(name) if rows.is_a?(Hash)

        rows.each do |row|
          raise ArgumentError, hash_input_message(name) if row.is_a?(Hash)
        end
      end

      def hash_input_message(name)
        "#{name} must be a model object; Hash input is not supported"
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
  end
end
