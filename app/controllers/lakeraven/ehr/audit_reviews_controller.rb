# frozen_string_literal: true

require "csv"

module Lakeraven
  module EHR
    # The audit log, for the person whose job is reading it.
    #
    # §164.308(a)(1)(ii)(D) expects someone in compliance to review PHI access
    # regularly. A log that can only be read with `rails console` does not
    # satisfy that — it makes every review a ticket, so reviews stop happening.
    #
    # Filters compose the model's review scopes: who, which record, which kind
    # of record, what they did, whether it was refused, which tenant, and a
    # date range. CSV for the ones that go into a report.
    #
    # THE CSV IS COMPLETE (S10 on #507): the first version silently truncated
    # at 10,000 rows while the screen told the reviewer to "download the CSV
    # for the rest" — a compliance report that omitted matching accesses with
    # no warning. The export now streams the entire matching relation in
    # batches; there is no cap to fall silently past.
    #
    # Reading this screen is ITSELF an audited access, filed under the human
    # who read it, and an EXPORT is recorded as an export — distinguishable
    # from merely opening the screen, because "who took the log away" is a
    # different fact from "who looked at it". If that record cannot be
    # written, the data is not served.
    class AuditReviewsController < WebController
      include AuditReviewerAuthorization

      PAGE_SIZE = 200
      CSV_COLUMNS = %w[
        id created_at event_type action outcome outcome_desc entity_type
        entity_identifier agent_who_type agent_who_identifier agent_name
        agent_network_address tenant_identifier facility_identifier
      ].freeze

      def index
        @filters = review_filters
        scope = AuditEvent.review(@filters)

        respond_to do |format|
          format.html do
            @events = scope.limit(PAGE_SIZE)
            @total = scope.count
            record_review_access!(event_type: "rest",
                                  desc: "audit review screen: #{@total} match(es)#{filter_summary}") or next
            render :index
          end
          format.csv do
            csv, rows = complete_csv(scope)
            record_review_access!(event_type: "export",
                                  desc: "audit CSV export: #{rows} row(s)#{filter_summary}") or next
            send_data csv, type: "text/csv", filename: csv_filename
          end
        end
      end

      private

      def fhir_resource_type = "AuditEvent"

      # The review screen is not a FHIR endpoint and has no :id/:dfn; naming
      # the filter keeps the row from claiming it touched a record it did not.
      def audit_entity_identifier = nil

      # `action` is taken by Rails, so the verb filter arrives as
      # `action_code`. A date that will not parse is REPORTED rather than
      # dropped: a filter that silently does nothing shows the reviewer more
      # than they asked for and tells them it is less. A date-only upper
      # bound means "through that day", not "until it began".
      def review_filters
        permitted = params.permit(:agent, :entity, :entity_type, :action_code, :outcome, :tenant, :from, :to)
                          .to_h.symbolize_keys
        @filter_errors = []

        filters = permitted.except(:action_code, :from, :to)
        filters[:action] = permitted[:action_code]
        filters[:from] = parse_time(permitted[:from], "from")
        filters[:to] = parse_time(permitted[:to], "to", end_of_day_when_dateonly: true)
        filters.compact_blank
      end

      def parse_time(value, label, end_of_day_when_dateonly: false)
        return nil if value.blank?

        time = Time.zone.parse(value.to_s) || raise(ArgumentError)
        time = time.end_of_day if end_of_day_when_dateonly && value.to_s.strip.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        time
      rescue ArgumentError, TypeError
        @filter_errors << "#{label}: #{value} is not a date this screen understands, so it was not applied"
        nil
      end

      # Reading (or exporting) the log is itself an access to who-saw-what,
      # recorded under the human who did it, FAIL CLOSED: if the record
      # cannot be written the data is not served. Returns false after
      # rendering the refusal so the caller can `or next`.
      #
      # Sets the one-row-per-request interlock: when the fail-closed audit
      # core (#512) has landed, its wrapper sees `@audit_recorded` and does
      # not write a second, less specific row.
      def record_review_access!(event_type:, desc:)
        AuditEvent.create!(
          event_type: event_type,
          action: "R",
          outcome: "0",
          outcome_desc: desc,
          entity_type: "AuditEvent",
          entity_identifier: nil,
          **reviewer_agent_attributes,
          agent_network_address: request.remote_ip,
          tenant_identifier: resolve_audit_context(:tenant_resolver),
          facility_identifier: resolve_audit_context(:facility_resolver)
        )
        @audit_recorded = true
      rescue StandardError => e
        Rails.logger.error("[audit] refusing to serve an unrecorded audit-log read: #{e.message}")
        render plain: "Service Unavailable: this access could not be recorded, so it was not completed",
               status: :service_unavailable
        false
      end

      # Which questions were asked, in identifiers only — the answer rows
      # never enter the log about the log.
      def filter_summary
        return "" if @filters.blank?

        "; filters: " + @filters.map { |key, value| "#{key}=#{value}" }.join(", ")
      end

      # The WHOLE matching relation, streamed in batches — never a silent
      # cap. `find_each` requires a primary-key order; export order is
      # therefore oldest-first, which suits an evidentiary record.
      def complete_csv(scope)
        rows = 0
        csv = CSV.generate do |out|
          out << CSV_COLUMNS
          scope.reorder(:id).find_each(batch_size: 1_000) do |event|
            out << CSV_COLUMNS.map { |column| event[column] }
            rows += 1
          end
        end
        [ csv, rows ]
      end

      def csv_filename
        "phi-access-audit-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.csv"
      end
    end
  end
end
