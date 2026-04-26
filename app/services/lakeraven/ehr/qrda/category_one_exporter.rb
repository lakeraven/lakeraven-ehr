# frozen_string_literal: true

# Qrda::CategoryOneExporter -- QRDA Category I XML export for individual
# patient quality reporting.
#
# ONC criteria: CMS QRDA Category I Implementation Guide
#
# Produces CDA R2 documents with:
#   - Patient demographics (recordTarget)
#   - Measure reference (NQF number + measurement period)
#   - Clinical data entries (conditions, observations)
#   - Population criteria results (IP, denominator, numerator)

module Lakeraven
  module EHR
    module Qrda
      class CategoryOneExporter
        # Well-known NQF numbers for supported measures
        NQF_MAP = {
          "diabetes_a1c_control" => "0059"
        }.freeze

        def self.generate(measure_report:, patient:, conditions: [], observations: [])
          new(
            measure_report: measure_report,
            patient: patient,
            conditions: conditions,
            observations: observations
          ).build
        end

        def initialize(measure_report:, patient:, conditions:, observations:)
          @report = measure_report
          @patient = patient
          @conditions = conditions
          @observations = observations
        end

        def build
          builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
            xml.ClinicalDocument(
              xmlns: "urn:hl7-org:v3",
              "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance"
            ) {
              build_template_ids(xml)
              build_document_code(xml)
              build_record_target(xml)
              build_measure_section(xml)
              build_clinical_entries(xml)
              build_population_criteria(xml)
            }
          end
          builder.to_xml
        end

        private

        def build_template_ids(xml)
          # CDA R2 header
          xml.templateId(root: "2.16.840.1.113883.10.20.22.1.1")
          # QRDA Category I
          xml.templateId(root: "2.16.840.1.113883.10.20.24.1.1")
        end

        def build_document_code(xml)
          # LOINC 55182-0 = Quality Measure Report
          xml.code(code: "55182-0", codeSystem: "2.16.840.1.113883.6.1",
                   displayName: "Quality Measure Report")
        end

        def build_record_target(xml)
          xml.recordTarget {
            xml.patientRole {
              xml.id(root: "2.16.840.1.113883.4.1", extension: @patient[:dfn])
              xml.patient {
                xml.name {
                  xml.given(@patient.dig(:name, :given))
                  xml.family(@patient.dig(:name, :family))
                }
                dob = @patient[:dob].to_s.delete("-")
                xml.birthTime(value: dob)
                xml.administrativeGenderCode(code: @patient[:sex])
              }
            }
          }
        end

        def build_measure_section(xml)
          nqf = NQF_MAP[@report.measure_id] || @report.measure_id
          xml.component {
            xml.section {
              xml.entry {
                xml.organizer(classCode: "CLUSTER", moodCode: "EVN") {
                  xml.reference {
                    xml.externalDocument {
                      xml.id(root: nqf)
                    }
                  }
                  xml.component {
                    xml.observation(classCode: "OBS", moodCode: "EVN") {
                      xml.code(code: "MSRTP", codeSystem: "2.16.840.1.113883.5.4")
                      xml.value("xsi:type" => "IVL_TS") {
                        xml.low(value: format_date(@report.period_start))
                        xml.high(value: format_date(@report.period_end))
                      }
                    }
                  }
                }
              }
            }
          }
        end

        def build_clinical_entries(xml)
          xml.component {
            xml.section {
              @conditions.each { |cond| build_condition_entry(xml, cond) }
              @observations.each { |obs| build_observation_entry(xml, obs) }
            }
          }
        end

        def build_condition_entry(xml, cond)
          xml.entry {
            xml.act(classCode: "ACT", moodCode: "EVN") {
              xml.entryRelationship(typeCode: "SUBJ") {
                xml.observation(classCode: "OBS", moodCode: "EVN") {
                  xml.code(code: cond.code, codeSystem: "2.16.840.1.113883.6.90",
                           displayName: cond.display)
                }
              }
            }
          }
        end

        def build_observation_entry(xml, obs)
          xml.entry {
            xml.observation(classCode: "OBS", moodCode: "EVN") {
              xml.code(code: obs.code, codeSystem: "2.16.840.1.113883.6.1",
                       displayName: obs.display)
              if obs.value.present?
                xml.value("xsi:type" => "PQ", value: obs.value, unit: obs.unit)
              end
              if obs.effective_datetime.present?
                xml.effectiveTime(value: obs.effective_datetime.strftime("%Y%m%d"))
              end
            }
          }
        end

        def build_population_criteria(xml)
          xml.component {
            xml.section {
              build_population_entry(xml, "2.16.840.1.113883.10.20.27.3.5",
                                     @report.initial_population_count)
              build_population_entry(xml, "2.16.840.1.113883.10.20.27.3.3",
                                     @report.denominator_count)
              build_population_entry(xml, "2.16.840.1.113883.10.20.27.3.4",
                                     @report.numerator_count)
            }
          }
        end

        def build_population_entry(xml, template_id, count)
          xml.entry {
            xml.observation(classCode: "OBS", moodCode: "EVN") {
              xml.templateId(root: template_id)
              xml.value("xsi:type" => "INT", value: count.to_s)
            }
          }
        end

        def format_date(date)
          return "" unless date

          date.strftime("%Y%m%d")
        end
      end
    end
  end
end
