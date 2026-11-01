# frozen_string_literal: true

require "rpms_rpc/api/patient"
require "rpms_rpc/api/patient_selection"

module Lakeraven
  module EHR
    # Finding a patient to open their chart (rpms-ux S-CHT-01.1, .2), the way
    # VueCentric's patient selection does: RpmsRpc::PatientSelection picks the
    # BEHOPTPL lookup from what was typed (a name, an HRN, a date of birth, the
    # last four of the SSN), on the user's own connection. Each patient listed
    # carries name, date of birth, sex and HRN from the brief header, never an
    # SSN.
    class ChartSearchGateway
      Match = Data.define(:dfn, :name, :dob, :sex, :hrn)

      LIMIT = 15
      RECENT_LIMIT = 10

      def self.find(text, via: ::RpmsRpc::PatientSelection, header: ::RpmsRpc::Patient)
        Array(via.find(text)).first(LIMIT).filter_map { |row| match(row[:dfn], header: header) }
      end

      # The patients this user opened, newest first (S-CHT-01.2): the opens the
      # audit trail recorded under their DUZ at this tenant, so another user on
      # the same workstation sees their own.
      def self.recent(duz, tenant:, header: ::RpmsRpc::Patient)
        return [] if duz.blank?

        AuditEvent.where(entity_type: "Patient", action: "E", outcome: "0", agent_who_type: "Practitioner",
                         agent_who_identifier: duz.to_s, tenant_identifier: tenant)
                  .group(:entity_identifier).order(Arel.sql("MAX(created_at) DESC")).limit(RECENT_LIMIT)
                  .pluck(:entity_identifier)
                  .filter_map { |dfn| match(dfn, header: header) }
      end

      def self.match(dfn, header:)
        found = header.brief_header(dfn.to_i)
        return unless found

        Match.new(dfn: dfn.to_i, name: found[:name], dob: found[:dob], sex: found[:sex], hrn: found[:mrn].presence)
      end
      private_class_method :match
    end
  end
end
