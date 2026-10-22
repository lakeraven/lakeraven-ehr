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
    # `_revinclude` rows (#631). `link` carries self, and next / previous when
    # those pages exist.
    #
    # A `_count` or `_offset` that is not a whole number in range is refused
    # with a 400 OperationOutcome. Clamping or ignoring it would hand the client
    # a page it did not ask for while it believes it got the one it did.
    #
    # FHIR::SearchCapabilities declares these parameters for the
    # CapabilityStatement, from the same constants this enforces.
    module FHIRSearchBundle
      extend ActiveSupport::Concern

      DEFAULT_COUNT = FHIR::SearchCapabilities::DEFAULT_COUNT
      MAX_COUNT = FHIR::SearchCapabilities::MAX_COUNT

      private

      # `if:` rather than `only: :index`: several controllers have no index,
      # and Rails refuses an `only:` naming an action a controller lacks.
      def fhir_search?
        action_name == "index"
      end

      # before_action on every FHIR search (see ApplicationController).
      def validate_fhir_paging!
        count = paging_integer(:_count)
        if count == :invalid || (count && count > MAX_COUNT)
          return refuse_search_parameter("_count", "a whole number from 0 to #{MAX_COUNT}")
        end

        offset = paging_integer(:_offset)
        return refuse_search_parameter("_offset", "a whole number from 0") if offset == :invalid

        @fhir_paging = { count: count || DEFAULT_COUNT, offset: offset || 0 }
      end

      # nil when the parameter is absent, :invalid when it is present and not
      # a whole number. An empty value is present, so it is invalid.
      def paging_integer(name)
        return nil unless params.key?(name)

        raw = params[name]
        raw.is_a?(String) && raw.match?(/\A\d+\z/) ? raw.to_i : :invalid
      end

      def refuse_search_parameter(name, expected)
        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "invalid",
          diagnostics: "Search parameter #{name} must be #{expected} (got #{params[name].inspect})"
        )
      end

      def fhir_paging
        @fhir_paging || { count: DEFAULT_COUNT, offset: 0 }
      end

      # The whole match set in, one page of it out.
      def fhir_search_bundle(entries, type: "searchset")
        page = fhir_page(entries).map { |entry| { resource: entry } }
        paged_search_bundle(page, total: entries.length, type: type)
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
      # other search parameter carries over, so following a link repeats the
      # same search.
      def fhir_page_url(offset)
        query = request.query_parameters.merge(
          "_count" => fhir_paging[:count].to_s,
          "_offset" => offset.to_s
        )
        "#{request.base_url}#{request.path}?#{query.to_query}"
      end
    end
  end
end
