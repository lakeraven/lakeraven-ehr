# frozen_string_literal: true

module Lakeraven
  module EHR
    # CcdaParser - Minimal parser for C-CDA round-trip testing
    # Sister to CcdaGenerator (ONC 170.315(b)(1) send path).
    # Lives in its own file so Zeitwerk can autoload it independently
    # of CcdaGenerator (the prior in-file nesting caused a seed-dependent
    # test flake — see lakeraven/lakeraven-ehr#351).
    #
    # Security labels (42 CFR Part 2, #908): every confidentialityCode, and
    # every v3-ActCode element carrying a Part 2 code (e.g. a DS4P security
    # observation value), is kept as a { system:, code: } label. Each entry
    # carries the document's, its section's and its own labels; a label
    # that is present but unreadable raises rather than being dropped.
    class CcdaParser
      NS = "urn:hl7-org:v3"
      XMLNS = { "xmlns" => NS }.freeze
      ACT_CODE_OID = "2.16.840.1.113883.5.4"
      CODE_SYSTEMS = {
        "2.16.840.1.113883.5.25" => "http://terminology.hl7.org/CodeSystem/v3-Confidentiality",
        ACT_CODE_OID => "http://terminology.hl7.org/CodeSystem/v3-ActCode"
      }.freeze
      ALLERGIES = "2.16.840.1.113883.10.20.22.2.6.1"
      PROBLEMS = "2.16.840.1.113883.10.20.22.2.5.1"
      MEDICATIONS = "2.16.840.1.113883.10.20.22.2.1.1"

      UnreadableSecurityLabel = Class.new(StandardError)

      def self.parse(xml)
        new.parse(xml)
      end

      def parse(xml)
        doc = Nokogiri::XML(xml)
        document_labels = labels_in(doc, outside: "section")
        {
          allergies: parse_allergies(doc, document_labels),
          conditions: parse_conditions(doc, document_labels),
          medications: parse_medications(doc, document_labels),
          security_labels: Part2RedisclosureNotice.label_fields(document_labels)[:security_labels]
        }
      end

      private

      def parse_allergies(doc, document_labels)
        entries(doc, ALLERGIES, document_labels) do |entry|
          code_node = entry.at_xpath(".//xmlns:playingEntity/xmlns:code", XMLNS)
          {
            allergen_code: code_node&.attr("code"),
            allergen_display: code_node&.attr("displayName")
          }
        end
      end

      def parse_conditions(doc, document_labels)
        entries(doc, PROBLEMS, document_labels) do |entry|
          value_node = entry.at_xpath(".//xmlns:observation/xmlns:value", XMLNS)
          {
            code: value_node&.attr("code"),
            display: value_node&.attr("displayName")
          }
        end
      end

      def parse_medications(doc, document_labels)
        entries(doc, MEDICATIONS, document_labels) do |entry|
          code_node = entry.at_xpath(".//xmlns:manufacturedMaterial/xmlns:code", XMLNS)
          {
            code: code_node&.attr("code"),
            display: code_node&.attr("displayName")
          }
        end
      end

      # Each entry of the section with this templateId, with the document's,
      # its enclosing sections' and its own labels.
      def entries(doc, template, document_labels)
        doc.xpath("//xmlns:section[xmlns:templateId[@root='#{template}']]//xmlns:entry", XMLNS).map do |entry|
          section_labels = entry.xpath("ancestor::xmlns:section", XMLNS).flat_map { |s| labels_in(s, outside: "entry") }
          labels = document_labels + section_labels + labels_in(entry)
          yield(entry).merge(Part2RedisclosureNotice.label_fields(labels))
        end
      end

      # Labels under node, leaving out those inside an `outside` element.
      def labels_in(node, outside: nil)
        guard = outside ? "[not(ancestor::xmlns:#{outside})]" : ""
        confidentiality = node.xpath(".//xmlns:confidentialityCode#{guard}", XMLNS)
        act_codes = node.xpath(".//*[normalize-space(@codeSystem)='#{ACT_CODE_OID}']#{guard}", XMLNS)
          .select { |element| Part2RedisclosureNotice.part2_code?(element["code"]) }
        (confidentiality.to_a + act_codes).map { |element| label(element) }
      end

      def label(element)
        code = element["code"]
        oid = element["codeSystem"].to_s.strip
        raise UnreadableSecurityLabel, "Unreadable security label: no code" if code.blank?
        raise UnreadableSecurityLabel, "Unreadable security label: no code system" if oid.empty?

        label = { system: CODE_SYSTEMS.fetch(oid) { "urn:oid:#{oid}" }, code: code }
        label[:display] = element["displayName"] if element["displayName"].present?
        label
      end
    end
  end
end
