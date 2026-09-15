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
    # of record, what they did, whether it was refused, and a date range. CSV
    # for the ones that go into a report.
    #
    # Reading this screen is ITSELF an audited access, filed under the human
    # who read it. Who-saw-what is exactly as sensitive as what they saw.
    class AuditReviewsController < WebController
      include AuditableClinicalAccess

      PAGE_SIZE = 200
      CSV_LIMIT = 10_000
      CSV_COLUMNS = %w[
        id created_at event_type action outcome outcome_desc entity_type
        entity_identifier agent_who_type agent_who_identifier agent_name
        agent_network_address tenant_identifier facility_identifier
      ].freeze

      before_action :require_authentication
      before_action :require_audit_reviewer!

      def index
        @filters = review_filters
        @events = AuditEvent.review(@filters).limit(PAGE_SIZE)
        @total = AuditEvent.review(@filters).count

        respond_to do |format|
          format.html
          format.csv { send_data review_csv, type: "text/csv", filename: csv_filename }
        end
      end

      # Tamper-evidence is worth stating out loud: a reviewer who assumes the
      # keyed answer when the log is unkeyed is being misled by omission.
      def integrity
        @integrity_mode = AuditEvent.integrity_mode
        @append_only = AuditEvent.append_only_enforceable?
        @unverified = AuditEvent.tampered_events
      end

      private

      def fhir_resource_type = "AuditEvent"

      # The review screen is not a FHIR endpoint and has no :id/:dfn; naming
      # the filter keeps the row from claiming it touched a record it did not.
      def audit_entity_identifier = nil

      # `action` is taken by Rails, so the verb filter arrives as
      # `action_code`. A date that will not parse is REPORTED rather than
      # dropped: a filter that silently does nothing shows the reviewer more
      # than they asked for and tells them it is less.
      def review_filters
        permitted = params.permit(:agent, :entity, :entity_type, :action_code, :outcome, :tenant, :from, :to)
                          .to_h.symbolize_keys
        @filter_errors = []

        filters = permitted.except(:action_code, :from, :to)
        filters[:action] = permitted[:action_code]
        filters[:from] = parse_time(permitted[:from], "from")
        filters[:to] = parse_time(permitted[:to], "to")
        filters.compact_blank
      end

      def parse_time(value, label)
        return nil if value.blank?

        Time.zone.parse(value.to_s) || raise(ArgumentError)
      rescue ArgumentError, TypeError
        @filter_errors << "#{label}: #{value} is not a date this screen understands, so it was not applied"
        nil
      end

      # WebController redirects an unauthenticated visitor to sign in. That is
      # a refusal, so it is noted as one — otherwise a 302 carries no status
      # the audit would recognise and the attempt goes unrecorded.
      def require_authentication
        return if session[:duz].present?

        note_audit_denial("audit review refused: not signed in")
        redirect_to login_path, alert: "Please sign in"
      end

      # Empty configuration is NOT "no restriction". The RPMS key that means
      # "may read the audit log" differs per site, and inventing a default
      # here would open the log to whatever that name happens to mean at a
      # real deployment.
      def require_audit_reviewer!
        allowed = Array(Lakeraven::EHR.configuration.audit_review_security_keys).map(&:to_s)

        if allowed.empty?
          return refuse("audit review refused: no reviewer security key is configured",
                        "Audit review is not configured. A site administrator must set " \
                        "`audit_review_security_keys` before the audit log can be read here.")
        end

        return if (current_security_keys.map(&:to_s) & allowed).any?

        refuse("audit review refused: #{session[:duz]} holds no reviewer security key",
               "Forbidden: reading the PHI access log requires an audit-reviewer security key.")
      end

      # The refusal names the reason and nothing else — never a count, never
      # a row, never the log it is refusing.
      def refuse(audit_reason, message)
        note_audit_denial(audit_reason)
        render plain: message, status: :forbidden
      end

      def review_csv
        rows = AuditEvent.review(@filters).limit(CSV_LIMIT)
        CSV.generate do |csv|
          csv << CSV_COLUMNS
          rows.each { |event| csv << CSV_COLUMNS.map { |column| event[column] } }
        end
      end

      def csv_filename
        "phi-access-audit-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.csv"
      end
    end
  end
end
