# frozen_string_literal: true

module Lakeraven
  module EHR
    # The patient's open visits, for a form that charts on one of them. The
    # same rule as the progress note form (#1001): a visit is open only when
    # RPMS reports it not locked (locked: false), an unstated lock state is
    # not open, and nil means the visits could not be read. An empty list is
    # also what an empty broker reply reads as.
    module OpenVisits
      extend ActiveSupport::Concern

      IEN_FORMAT = /\A[0-9]+\z/
      UNREAD_VISIT_ERRORS = [ ::RpmsRpc::Error, IOError, SystemCallError ].freeze

      included do
        helper_method :visit_label
      end

      private

      def read_open_visits(dfn)
        rows = EncounterGateway.visits(dfn)
        Array(rows).select { |row| row.is_a?(Hash) && row[:locked] == false && canonical_ien(row[:visit_ien]) }
      rescue ::RpmsRpc::NotConfiguredError
        raise
      rescue *UNREAD_VISIT_ERRORS => error
        Rails.logger.error("[open_visits] visit read raised #{error.class}")
        nil
      end

      # The open visit the form posted, read again from RPMS, or nil: a visit
      # not open now, or not this patient's, is not charted on.
      def chosen_open_visit(dfn, posted_ien)
        ien = canonical_ien(posted_ien)
        ien && Array(read_open_visits(dfn)).find { |row| canonical_ien(row[:visit_ien]) == ien }
      end

      # A positive integer, as a string without leading zeros, or nil.
      def canonical_ien(value)
        return unless value.is_a?(String) || value.is_a?(Integer)

        text = value.to_s
        return unless text.match?(IEN_FORMAT)

        ien = Integer(text, 10)
        ien.to_s if ien.positive?
      end

      def visit_label(row)
        when_seen = row[:datetime]
        stamp = when_seen.respond_to?(:strftime) ? when_seen.strftime("%b %-d, %Y %-l:%M %p") : when_seen.to_s
        [ stamp.presence, row[:location].to_s.presence || "Unknown location" ].compact.join(" · ")
      end
    end
  end
end
