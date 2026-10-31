# frozen_string_literal: true

module Lakeraven
  module EHR
    # The searchset Bundle every FHIR search renders, and the result
    # parameters that shape it.
    #
    # Every index on ApplicationController is a FHIR search, so the result
    # parameters live here once rather than in each controller.
    #
    # Paging (#648): `_count` (default 20, at most 100) and `_offset` cut one
    # page out of the full match set, in the order the backend returned it, so
    # for a fixed result set the same `_offset` always yields the same entries.
    # `total` is the size of the match set: not of the page, and not of any
    # `_include` / `_revinclude` rows (#631). `link` carries self, and next /
    # previous when those pages exist.
    #
    # A `_count` or `_offset` that is not a whole number in range is refused
    # with a 400 OperationOutcome. Clamping or ignoring it would hand the client
    # a page it did not ask for while it believes it got the one it did.
    #
    # Sorting (#649): `_sort` names search parameters, comma-separated, `-` for
    # descending. The match set is sorted before it is paged, so pages follow
    # the sort. Ties keep the backend's order, and a match with no value sorts
    # last in either direction, so paging stays stable.
    #
    # Including (#649): `_include` follows forward references from the matches
    # on this page and appends what they point at, with search.mode "include".
    # An included resource is a read of its own type, so it needs the same
    # scope, and a Patient the same compartment, as a direct read of it. One
    # the token may not read is withheld, and an OperationOutcome entry says
    # so. Includes go into the same Bundle as the matches, so
    # render_bundle_egress hands both to the Part 2 egress seam.
    #
    # A `_sort`, `_include` or `_revinclude` value this resource does not
    # declare is refused with a 400 OperationOutcome naming it, like a bad
    # `_count`. The controller follows a declared `_revinclude` itself
    # (PatientsController: Provenance:target).
    #
    # FHIR::SearchCapabilities declares all of this for the
    # CapabilityStatement, and is what this enforces.
    module FHIRSearchBundle
      extend ActiveSupport::Concern

      DEFAULT_COUNT = FHIR::SearchCapabilities::DEFAULT_COUNT
      MAX_COUNT = FHIR::SearchCapabilities::MAX_COUNT

      # How each type an _include may point at is read: the same lookups the
      # direct reads (PatientsController#show, PractitionersController#show)
      # make.
      INCLUDE_READERS = {
        "Patient" => ->(id) { Patient.find_by_dfn(id)&.to_fhir },
        "Practitioner" => ->(id) { Practitioner.find_by_ien(id)&.to_fhir }
      }.freeze

      private

      # `if:` rather than `only: :index`: several controllers have no index,
      # and Rails refuses an `only:` naming an action a controller lacks.
      def fhir_search?
        action_name == "index"
      end

      # -- Validation (before_action on every FHIR search) -----------------------

      def validate_fhir_paging!
        count = paging_integer(:_count)
        if count == :invalid || (count && count > MAX_COUNT)
          return refuse_search_parameter("_count", "a whole number from 0 to #{MAX_COUNT}")
        end

        offset = paging_integer(:_offset)
        return refuse_search_parameter("_offset", "a whole number from 0") if offset == :invalid

        @fhir_paging = { count: count || DEFAULT_COUNT, offset: offset || 0 }
      end

      def validate_fhir_sort_and_include!
        @fhir_sort = parse_fhir_sort
        @fhir_includes = parse_fhir_includes unless performed?
        validate_fhir_revincludes unless performed?
      end

      # nil when the parameter is absent, :invalid when it is present and not
      # a whole number. An empty value is present, so it is invalid.
      def paging_integer(name)
        return nil unless params.key?(name)

        raw = params[name]
        raw.is_a?(String) && raw.match?(/\A\d+\z/) ? raw.to_i : :invalid
      end

      # [[name, Sort, descending?], ...] in the order given.
      def parse_fhir_sort
        return [] unless params.key?(:_sort)

        raw = params[:_sort]
        return refuse_unsupported("_sort", raw.to_s, fhir_sorts.keys) unless raw.is_a?(String) && raw.strip.present?

        raw.split(",", -1).map(&:strip).map do |token|
          name = token.delete_prefix("-")
          sort = fhir_sorts[name]
          return refuse_unsupported("_sort", token, fhir_sorts.keys) unless sort

          [ name, sort, token.start_with?("-") ]
        end
      end

      # Every _include value (FHIR repeats the parameter rather than joining
      # it), each one declared for this resource. An `_include:<modifier>`
      # (iterate, recurse) is refused rather than read as a plain _include.
      def parse_fhir_includes
        modified = raw_query.keys.find { |key| key.start_with?("_include:") }
        return refuse_unsupported(modified, Array(raw_query[modified]).first.to_s, []) if modified

        Array(raw_query["_include"]).map do |value|
          inclusion = fhir_include_declarations[value]
          return refuse_unsupported("_include", value, fhir_include_declarations.keys) unless inclusion

          inclusion
        end.uniq
      end

      # Every _revinclude value declared for this resource. Like _include, a
      # modifier is refused rather than read as the plain parameter.
      def validate_fhir_revincludes
        modified = raw_query.keys.find { |key| key.start_with?("_revinclude:") }
        return refuse_unsupported(modified, Array(raw_query[modified]).first.to_s, []) if modified

        declared = FHIR::SearchCapabilities.revincludes_for(fhir_resource_type)
        Array(raw_query["_revinclude"]).each do |value|
          return refuse_unsupported("_revinclude", value, declared) unless declared.include?(value)
        end
      end

      def fhir_sorts
        FHIR::SearchCapabilities.sorts_for(fhir_resource_type)
      end

      def fhir_include_declarations
        FHIR::SearchCapabilities.includes_for(fhir_resource_type)
      end

      def refuse_search_parameter(name, expected)
        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "invalid",
          diagnostics: "Search parameter #{name} must be #{expected} (got #{params[name].inspect})"
        )
      end

      def refuse_unsupported(name, value, supported)
        offered = if supported.any?
          "#{fhir_resource_type} supports: #{supported.join(', ')}"
        else
          "#{fhir_resource_type} supports none"
        end
        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "not-supported",
          diagnostics: "#{name} value #{value.inspect} is not supported. #{offered}."
        )
      end

      # The query string as sent, repeated keys kept. Rails' params keep only
      # the last of a repeated key, and _include repeats.
      def raw_query
        @raw_query ||= Rack::Utils.parse_query(request.query_string)
      end

      # -- Bundle -------------------------------------------------------------------

      def fhir_paging
        @fhir_paging || { count: DEFAULT_COUNT, offset: 0 }
      end

      # The whole match set in: sorted, one page of it out, and whatever
      # _include asks for after the page.
      def fhir_search_bundle(entries, type: "searchset")
        page = fhir_page(fhir_sort(entries))
        matches = page.map { |entry| { resource: entry, search: { mode: "match" } } }
        paged_search_bundle(matches + fhir_include_entries(page), total: entries.length, type: type)
      end

      def fhir_page(matches)
        matches.drop(fhir_paging[:offset]).first(fhir_paging[:count])
      end

      # For a caller that cut its own page (a database query, or a search
      # that appends _revinclude rows after its matches). `total` is the size
      # of the match set the page was cut from.
      def paged_search_bundle(page_entries, total:, type: "searchset")
        {
          resourceType: "Bundle",
          type: type,
          total: total,
          link: fhir_paging_links(total),
          entry: page_entries
        }
      end

      def fhir_paging_links(total)
        count = fhir_paging[:count]
        offset = fhir_paging[:offset]
        links = [ { relation: "self", url: fhir_page_url(offset) } ]
        # _count=0 asks for the total alone: there is no next page of nothing.
        return links if count.zero?

        links << { relation: "next", url: fhir_page_url(offset + count) } if offset + count < total
        links << { relation: "previous", url: fhir_page_url(previous_offset(offset, count, total)) } if offset.positive?
        links
      end

      # One page back, but never past the end: from an _offset beyond the
      # match set, previous is the last page that has entries.
      def previous_offset(offset, count, total)
        previous = [ offset - count, 0 ].max
        previous < total ? previous : [ total - count, 0 ].max
      end

      # The request's own query, with this page's _count and _offset. Every
      # other search parameter carries over, a repeated one (_include) as
      # often as it was sent, so following a link repeats the same search.
      def fhir_page_url(offset)
        query = raw_query.merge(
          "_count" => fhir_paging[:count].to_s,
          "_offset" => offset.to_s
        )
        "#{request.base_url}#{request.path}?#{Rack::Utils.build_query(query)}"
      end

      # -- _sort --------------------------------------------------------------------

      # Stable: ties keep their input order, so equal matches never swap
      # places between two requests for neighbouring pages.
      def fhir_sort(resources)
        return resources if fhir_sort_keys.empty?

        resources.each_with_index
                 .sort { |(a, ia), (b, ib)| compare_for_sort(a, b).nonzero? || (ia <=> ib) }
                 .map(&:first)
      end

      def fhir_sort_keys
        @fhir_sort || []
      end

      def compare_for_sort(a, b)
        fhir_sort_keys.each do |_name, sort, descending|
          sort.paths.each do |path|
            order = compare_values(sort_value(a, path, sort.type), sort_value(b, path, sort.type), descending)
            return order unless order.zero?
          end
        end
        0
      end

      # A missing value sorts last whichever way the sort runs.
      def compare_values(left, right, descending)
        return 0 if left.nil? && right.nil?
        return 1 if left.nil?
        return -1 if right.nil?

        descending ? right <=> left : left <=> right
      end

      # Dates compare as instants. Otherwise digits compare as numbers (DFN 10
      # after DFN 9) and the rest as case-folded text, digits first.
      def sort_value(resource, path, type)
        raw = dig_fhir(resource, path).first
        return nil if raw.nil? || raw.to_s.empty?
        return sort_date(raw) if type == :date

        text = raw.to_s
        text.match?(/\A\d+\z/) ? [ 0, text.to_i, "" ] : [ 1, 0, text.downcase ]
      end

      def sort_date(raw)
        DateTime.iso8601(raw.to_s)
      rescue Date::Error
        nil
      end

      # Every value at `path`, reading String or Symbol keys. `:*` walks each
      # element of an array.
      def dig_fhir(node, path)
        return [ node ] if path.empty?

        key, *rest = path
        case node
        when Hash
          child = node.key?(key) ? node[key] : node[key.to_s]
          child.nil? ? [] : dig_fhir(child, rest)
        when Array
          return node.flat_map { |element| dig_fhir(element, rest) } if key == :*

          key.is_a?(Integer) && !node[key].nil? ? dig_fhir(node[key], rest) : []
        else
          []
        end
      end

      # -- _include -----------------------------------------------------------------

      def fhir_include_entries(page)
        includes = @fhir_includes || []
        return [] if includes.empty?

        references = includes.flat_map do |inclusion|
          page.flat_map { |resource| include_references(resource, inclusion) }
        end.uniq

        readable, withheld = references.partition { |type, id| may_read_included?(type, id) }
        entries = readable.filter_map do |type, id|
          resource = INCLUDE_READERS.fetch(type).call(id)
          { resource: resource, search: { mode: "include" } } if resource
        end
        entries + withheld_include_outcome(withheld)
      end

      # [[type, id], ...] for the references at the include's paths that point
      # at its declared target type.
      def include_references(resource, inclusion)
        inclusion.paths.flat_map { |path| dig_fhir(resource, path) }.filter_map do |reference|
          type, id = reference.to_s.split("/", 2)
          [ type, id ] if type == inclusion.target && id.present?
        end
      end

      # The checks a direct read of the same resource makes: read scope for
      # its type, and for a Patient the token's own compartment
      # (SmartAuthentication#authorize_patient_context!).
      def may_read_included?(type, id)
        return false unless can_read?(type)
        return true unless type == "Patient" && patient_context_scope?

        bound = current_token.resource_owner_id.to_s
        bound.present? && bound == id
      end

      def withheld_include_outcome(withheld)
        return [] if withheld.empty?

        types = withheld.map(&:first).uniq.join(", ")
        [ {
          resource: {
            resourceType: "OperationOutcome",
            issue: [ {
              severity: "warning",
              code: "forbidden",
              diagnostics: "Included #{types} resources were withheld: this token may not read them."
            } ]
          },
          search: { mode: "outcome" }
        } ]
      end
    end
  end
end
