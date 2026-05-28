# frozen_string_literal: true

module Lakeraven
  module EHR
    # CcdaParser - Minimal parser for C-CDA round-trip testing
    # Sister to CcdaGenerator (ONC 170.315(b)(1) send path).
    # Lives in its own file so Zeitwerk can autoload it independently
    # of CcdaGenerator (the prior in-file nesting caused a seed-dependent
    # test flake — see lakeraven/lakeraven-ehr#351).
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
