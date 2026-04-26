# frozen_string_literal: true

# Qrda::CategoryThreeExporter -- QRDA Category III XML export for aggregate
# quality reporting.
#
# ONC criteria: CMS QRDA Category III Implementation Guide
#
# Produces CDA R2 documents with:
#   - QRDA III template IDs
#   - Measure reference (NQF number + measurement period)
#   - Aggregate population counts (IP, denominator, numerator)
#   - Performance rate calculation

module Lakeraven
  module EHR
    module Qrda
      class CategoryThreeExporter
        NQF_MAP = {
          "diabetes_a1c_control" => "0059"
        }.freeze

        def self.generate(measure_report:)
          new(measure_report: measure_report).build
        end

        def initialize(measure_report:)
          @report = measure_report
        end

        def build
          builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
            xml.ClinicalDocument(
              xmlns: "urn:hl7-org:v3",
              "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance"
            ) {
              build_template_ids(xml)
              build_document_code(xml)
              build_measure_section(xml)
              build_population_section(xml)
            }
          end
          builder.to_xml
        end

        private

        def build_template_ids(xml)
          xml.templateId(root: "2.16.840.1.113883.10.20.22.1.1")
          xml.templateId(root: "2.16.840.1.113883.10.20.27.1.1")
        end

        def build_document_code(xml)
          xml.code(code: "55184-6", codeSystem: "2.16.840.1.113883.6.1",
                   displayName: "Quality Reporting Document Architecture Calculated Summary Report")
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

        def build_population_section(xml)
          xml.component {
            xml.section {
              build_population_entry(xml, "2.16.840.1.113883.10.20.27.3.5",
                                     @report.initial_population_count)
              build_population_entry(xml, "2.16.840.1.113883.10.20.27.3.3",
                                     @report.denominator_count)
              build_population_entry(xml, "2.16.840.1.113883.10.20.27.3.4",
                                     @report.numerator_count)
              build_performance_rate_entry(xml)
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

        def build_performance_rate_entry(xml)
          rate = @report.performance_rate
          return unless rate

          xml.entry {
            xml.observation(classCode: "OBS", moodCode: "EVN") {
              xml.templateId(root: "2.16.840.1.113883.10.20.27.3.14")
              xml.value("xsi:type" => "REAL", value: rate.to_s)
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
