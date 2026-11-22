# frozen_string_literal: true

module Lakeraven
  module EHR
    # CcdaParser - Minimal parser for C-CDA round-trip testing
    # Sister to CcdaGenerator (ONC 170.315(b)(1) send path).
    # Lives in its own file so Zeitwerk can autoload it independently
    # of CcdaGenerator (the prior in-file nesting caused a seed-dependent
    # test flake — see lakeraven/lakeraven-ehr#351).
    #
    # Security labels (42 CFR Part 2, #908). A label is a confidentialityCode,
    # or any element whose codeSystem is v3-Confidentiality or whose code is
    # a Part 2 code. It belongs to the narrowest entry holding it whose
    # clinical content was found, else the imported section (by templateId)
    # holding it, else the document. Every entry of an imported section is
    # an item; it carries the labels owned by itself, its sections and the
    # document, so a label-only entry's labels reach its siblings. A label with
    # no code or codeSystem marks its scope part2: true with no label value.
    # Top-level part2 is true for any Part 2 or unreadable label anywhere.
    # XML that is not (namespace-)well-formed, has a DOCTYPE (entities could hide
    # labels), or is not a v3 ClinicalDocument, raises.
    class CcdaParser
      NS = "urn:hl7-org:v3"
      XMLNS = { "xmlns" => NS }.freeze
      CONFIDENTIALITY_OID = "2.16.840.1.113883.5.25"
      CODE_SYSTEMS = {
        CONFIDENTIALITY_OID => "http://terminology.hl7.org/CodeSystem/v3-Confidentiality",
        "2.16.840.1.113883.5.4" => "http://terminology.hl7.org/CodeSystem/v3-ActCode"
      }.freeze
      # Imported sections: result key => [templateId, clinical node, code
      # field, display field].
      SECTIONS = {
        allergies: [ "2.16.840.1.113883.10.20.22.2.6.1", ".//xmlns:playingEntity/xmlns:code", :allergen_code, :allergen_display ],
        conditions: [ "2.16.840.1.113883.10.20.22.2.5.1", ".//xmlns:observation/xmlns:value", :code, :display ],
        medications: [ "2.16.840.1.113883.10.20.22.2.1.1", ".//xmlns:manufacturedMaterial/xmlns:code", :code, :display ]
      }.freeze

      Malformed = Class.new(StandardError)

      def self.parse(xml)
        new.parse(xml)
      end

      def parse(xml)
        doc = Nokogiri::XML(xml) { |config| config.strict.nonet }
        raise Malformed, "C-CDA is not well-formed" if doc.errors.any? # e.g. an unbound namespace prefix
        raise Malformed, "C-CDA must not have a DOCTYPE" if doc.internal_subset || doc.external_subset

        root = doc.root
        raise Malformed, "Not a C-CDA ClinicalDocument" unless root&.name == "ClinicalDocument" && root.namespace&.href == NS

        entries = SECTIONS.transform_values { |spec| section_entries(doc, *spec) }
        content_entries = entries.values.flatten(1).filter_map { |entry, _, content| entry if content }
        imported_sections = doc.xpath(SECTIONS.values.map { |template, *| section_xpath(template) }.join(" | "), XMLNS)
        marks = owned_marks(doc, content_entries + imported_sections.to_a)
        document = marks.fetch(nil, [])
        inheriting = {} # section pointer_ids => fields for document + those sections

        entries.transform_values do |list|
          list.map do |entry, fields, _|
            sections, own = [ entry, *entry.ancestors ].select { |node| marks.key?(node.pointer_id) }
              .partition { |node| node.name == "section" }
            merge = inheriting[sections.map(&:pointer_id)] ||=
              Part2RedisclosureNotice.inheriting(document + sections.flat_map { |node| marks[node.pointer_id] })
            fields.merge(merge.call(own.flat_map { |node| marks[node.pointer_id] }))
          end
        end.merge(
          security_labels: Part2RedisclosureNotice.label_fields(document)[:security_labels],
          part2: Part2RedisclosureNotice.label_fields(marks.values.flatten)[:part2]
        )
      end

      private

      def section_xpath(template) = "//xmlns:section[xmlns:templateId[@root='#{template}']]"

      # [entry, fields, clinical content found?] for each entry of the section.
      def section_entries(doc, template, node_xpath, code_field, display_field)
        doc.xpath("#{section_xpath(template)}//xmlns:entry", XMLNS).map do |entry|
          node = entry.at_xpath(node_xpath, XMLNS)
          [ entry, { code_field => node&.attr("code"), display_field => node&.attr("displayName") }, !node.nil? ]
        end
      end

      # Marks keyed by the pointer_id of the nearest owning scope among
      # `owners`, or nil for the document.
      def owned_marks(doc, owners)
        owner_ids = owners.map(&:pointer_id).to_set
        doc.xpath("//*").each_with_object({}) do |element, marks|
          mark = mark(element) or next
          owner = element.ancestors.find { |node| owner_ids.include?(node.pointer_id) }
          (marks[owner&.pointer_id] ||= []) << mark
        end
      end

      def mark(element)
        code = element["code"]
        oid = Part2RedisclosureNotice.unpad(Part2RedisclosureNotice.unpad(element["codeSystem"]).sub(/\Aurn:oid:/i, ""))
        confidentiality = element.name == "confidentialityCode" # in any namespace
        return unless confidentiality || oid == CONFIDENTIALITY_OID || Part2RedisclosureNotice.part2_code?(code)
        return Part2RedisclosureNotice::UNREADABLE if Part2RedisclosureNotice.unpad(code).empty? || oid.empty?

        label = { system: CODE_SYSTEMS.fetch(oid) { "urn:oid:#{oid}" }, code: code }
        label[:display] = element["displayName"] if element["displayName"].present?
        label
      end
    end
  end
end
