# frozen_string_literal: true

module Lakeraven
  module EHR
    # Egress seam for a disclosing response.
    #
    # Callers pass the payload they are about to send: C-CDA sections
    # (TransitionsOfCareController), a FHIR resource or Bundle hash, or
    # an export file (String: NDJSON, CSV, or JSON). TransitionsOfCareController
    # serializes sections and does not build a document when the return
    # value is not a sections hash. FHIR and NDJSON callers render the
    # return value, and refuse when it is nil or not usable for that
    # response.
    #
    # What this method does (42 CFR § 2.32): every FHIR resource whose
    # meta.security has a Part 2 code leaves with the NORDSCLCD refrain
    # coding and the redisclosure notice extension (Part2RedisclosureNotice),
    # and so does a Bundle that holds one. NDJSON is handled line by line.
    # It returns nil (refuse) when a labelled resource's meta cannot carry
    # the notice, or when a Part 2 label sits where it cannot be noticed
    # (C-CDA rows, non-FHIR lines). Unlabelled payloads come back unchanged
    # and the input is never mutated. It does not classify unlabelled
    # records; keeping labels on ingest is #908.
    class Part2EgressFilter
      Refused = Class.new(StandardError)
      private_constant :Refused

      def self.call(payload)
        result = new.send(:filter, payload)
        result.equal?(payload) ? payload : result.deep_dup
      rescue Refused
        nil
      end

      private

      def filter(payload)
        payload.is_a?(String) ? filter_lines(payload) : walk(payload)
      end

      def filter_lines(text)
        lines = text.split("\n", -1)
        out = lines.map { |line| filter_line(line) }
        out.zip(lines).all? { |a, b| a.equal?(b) } ? text : out.join("\n")
      end

      def filter_line(line)
        parsed = parse_json(line)
        if resource?(parsed)
          result = walk(parsed)
          return result == parsed ? line : result.to_json
        end
        raise Refused if line.include?("42CFRPart2")
        # Not a resource line, so a label inside it has nowhere to be noticed.
        raise Refused unless walk(parsed) == parsed

        line
      end

      def parse_json(line)
        JSON.parse(line)
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
        raise Refused if key.to_s == "security" && part2_code?(value)

        walk(value)
      end

      def walk_resource(resource)
        outer = @labelled
        @labelled = false
        meta_key = key_for(resource, "meta")
        children = rebuild(resource, resource.to_h { |key, value| [ key, key == meta_key ? value : walk_pair(key, value) ] })
        inner = @labelled
        own = labelled_meta?(resource[meta_key])
        @labelled = outer || inner || own
        return children unless own || (inner && bundle?(resource))

        children.merge(meta_key => noticed_meta(resource[meta_key], meta_key.is_a?(Symbol)))
      end

      # Whether meta.security holds a Part 2 code. A label anywhere else in
      # meta, or in a meta that is not a Hash, cannot be noticed: refuse.
      def labelled_meta?(meta)
        unless meta.is_a?(Hash)
          raise Refused unless walk(meta) == meta

          return false
        end

        security_key = key_for(meta, "security")
        meta.each { |key, value| raise Refused unless key == security_key || walk_pair(key, value) == value }
        security = meta[security_key]
        return part2_code?(security) if security.is_a?(Array)
        raise Refused if part2_code?(security)

        false
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
        notice = Part2RedisclosureNotice::EXTENSION
        has_refrain = security.any? { |c| c.is_a?(Hash) && c.stringify_keys.slice("system", "code") == refrain }
        has_notice = extensions.any? { |e| e.is_a?(Hash) && e.stringify_keys == notice }
        meta.merge(
          security_key => security + (has_refrain ? [] : [ styled(refrain, symbols) ]),
          extension_key => extensions + (has_notice ? [] : [ styled(notice, symbols) ])
        )
      end

      def part2_code?(value)
        codings = value.is_a?(Hash) ? [ value ] : Array(value)
        codings.any? do |coding|
          coding.is_a?(Hash) &&
            Part2RedisclosureNotice::PART2_CODES.include?(coding["code"] || coding[:code])
        end
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

      def bundle?(resource)
        (resource["resourceType"] || resource[:resourceType]) == "Bundle"
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
