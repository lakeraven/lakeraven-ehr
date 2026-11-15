# frozen_string_literal: true

module Lakeraven
  module EHR
    # Egress seam for a disclosing response (42 CFR § 2.32).
    #
    # Callers pass the payload they are about to send: C-CDA sections, a
    # FHIR resource or Bundle hash, or an export String (NDJSON, CSV, JSON).
    # Every resource whose meta.security has a Part 2 code, and every
    # resource that holds one at any depth, leaves with the NORDSCLCD
    # refrain coding and exactly one current notice extension
    # (Part2RedisclosureNotice). It returns nil (refuse) when a label sits
    # where it cannot be noticed: elsewhere in meta, outside a resource
    # (C-CDA rows, non-FHIR lines), in a multi-line JSON document. It also
    # returns nil for invalid encoding and on any error (fail closed).
    # Unlabelled payloads come back unchanged; the input is never mutated.
    # It does not classify unlabelled records; keeping labels on ingest is #908.
    class Part2EgressFilter
      Refused = Class.new(StandardError)
      private_constant :Refused

      BOM = "﻿"
      SHORT_CODES = Part2RedisclosureNotice::PART2_CODES - %w[42CFRPart2]
      TEXT_LABEL = Regexp.union(/42cfrpart2/i, /\b(?:#{SHORT_CODES.join('|')})\b/)
      private_constant :BOM, :SHORT_CODES, :TEXT_LABEL

      def self.call(payload)
        result = new.send(:filter, payload)
        result.equal?(payload) ? payload : result.deep_dup
      rescue StandardError
        nil
      end

      private

      def filter(payload)
        payload.is_a?(String) ? filter_string(payload) : walk(payload)
      end

      def filter_string(text)
        raise Refused unless text.valid_encoding?
        return filter_lines(text) unless text.chomp.include?("\n")

        document = parse_json(text.delete_prefix(BOM))
        return filter_lines(text) if document.nil?
        # Pretty JSON is not re-serialised: a labelled document is refused.
        raise Refused unless walk(document).equal?(document)

        text
      end

      def filter_lines(text)
        lines = text.split("\n", -1)
        out = lines.map { |line| filter_line(line) }
        out.zip(lines).all? { |a, b| a.equal?(b) } ? text : out.join("\n")
      end

      def filter_line(line)
        parsed = parse_json(line.delete_prefix(BOM))
        if resource?(parsed)
          result = walk(parsed)
          return result.equal?(parsed) ? line : result.to_json
        end
        # Not a resource line, so a label inside it has nowhere to be noticed.
        raise Refused if parsed.nil? ? line.match?(TEXT_LABEL) : line.match?(/42cfrpart2/i)
        raise Refused unless walk(parsed).equal?(parsed)

        line
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      def walk(node)
        case node
        when Array then rebuild(node, node.map { |value| walk(value) })
        when Hash then resource?(node) ? walk_resource(node) : walk_hash(node)
        else node
        end
      end

      def walk_hash(hash)
        rebuild(hash, hash.to_h { |key, value| [ key, walk_pair(key, value) ] })
      end

      # A Part 2 code under a security key outside a resource's meta.
      def walk_pair(key, value)
        raise Refused if key.to_s == "security" && part2_anywhere?(value)

        walk(value)
      end

      def walk_resource(resource)
        outer = @labelled
        @labelled = false
        meta_key = key_for(resource, "meta")
        children = rebuild(resource, resource.to_h { |key, value| [ key, key == meta_key ? value : walk_pair(key, value) ] })
        noticed = @labelled || labelled_meta?(resource[meta_key])
        @labelled = outer || noticed
        return children unless noticed

        children.merge(meta_key => noticed_meta(resource[meta_key], meta_key.is_a?(Symbol)))
      end

      # Whether a flat Coding in meta.security has a Part 2 code. A Part 2
      # code anywhere else in meta cannot be noticed: refuse.
      def labelled_meta?(meta)
        security_key = meta.is_a?(Hash) && key_for(meta, "security")
        security = security_key && meta[security_key]
        codings = security.is_a?(Array) ? security.select { |item| item.is_a?(Hash) } : []
        elsewhere = codings.empty? ? meta : meta.merge(security_key => security.map { |item| item.is_a?(Hash) ? item.except("code", :code) : item })
        raise Refused if part2_anywhere?(elsewhere)

        codings.any? { |coding| part2?(coding.key?("code") ? coding["code"] : coding[:code]) }
      end

      def noticed_meta(meta, symbols)
        meta = {} if meta.nil?
        raise Refused unless meta.is_a?(Hash)

        security_key = key_for(meta, "security", symbols)
        extension_key = key_for(meta, "extension", symbols)
        security = meta.fetch(security_key, [])
        extensions = meta.fetch(extension_key, [])
        raise Refused unless security.is_a?(Array) && extensions.is_a?(Array)

        refrain = Part2RedisclosureNotice::REFRAIN
        has_refrain = security.any? { |c| c.is_a?(Hash) && c.stringify_keys.slice("system", "code") == refrain }
        current = extensions.reject { |e| e.is_a?(Hash) && (e["url"] || e[:url]) == Part2RedisclosureNotice::EXTENSION_URL }
        meta.merge(
          security_key => security + (has_refrain ? [] : [ styled(refrain, symbols) ]),
          extension_key => current + [ styled(Part2RedisclosureNotice::EXTENSION, symbols) ]
        )
      end

      # Any value at any depth that is a Part 2 code. The notice extension
      # never matches: its url and text are not codes.
      def part2_anywhere?(node)
        case node
        when Hash then node.each_value.any? { |value| part2_anywhere?(value) }
        when Array then node.any? { |value| part2_anywhere?(value) }
        else part2?(node)
        end
      end

      def part2?(code)
        value = code.to_s.strip
        Part2RedisclosureNotice::PART2_CODES.any? { |part2| part2.casecmp?(value) }
      end

      def resource?(value)
        return false unless value.is_a?(Hash)

        type = value["resourceType"] || value[:resourceType]
        type.is_a?(String) && !type.empty?
      end

      # The key already in use for `name`, else one in the hash's key style.
      def key_for(hash, name, symbols = hash.keys.first.is_a?(Symbol))
        return name if hash.key?(name)
        return name.to_sym if hash.key?(name.to_sym)

        symbols ? name.to_sym : name
      end

      def styled(hash, symbols)
        symbols ? hash.symbolize_keys : hash.dup
      end

      # `values` (same shape as `original`), or `original` itself when no
      # value changed, so an unlabelled payload comes back as given.
      def rebuild(original, values)
        pairs = original.is_a?(Hash) ? values.map { |key, value| [ value, original[key] ] } : values.zip(original)
        pairs.all? { |new_value, old_value| new_value.equal?(old_value) } ? original : values
      end
    end
  end
end
