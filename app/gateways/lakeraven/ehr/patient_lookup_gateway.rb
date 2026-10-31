# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    # The front desk's patient lookup (rpms-ux S-REG-01): AGG LOOKUP PATIENTS,
    # IHS registration's own division-aware search (FND^AGGPTLKP), through
    # RpmsRpc::Patient.lookup. One text searches every cross-reference: name,
    # health record number, SSN, date of birth. Inactive charts are included and
    # marked, so a clerk does not mistake one for an active patient.
    #
    # A lookup that fails raises; it never answers "no match". At the front desk
    # "no match" leads to registering a new patient, so an unreadable reply must
    # not look like one (require_response).
    class PatientLookupGateway
      Match = Data.define(:dfn, :name, :hrn, :dob, :dod, :inactive) do
        def deceased? = dod.present?
        def inactive? = inactive

        def status
          return "Deceased" if deceased?
          return "Inactive" if inactive?

          "Active"
        end
      end

      # text: what the clerk typed. dob: a Date that narrows the matches to the
      # patients born on it, so a name and a date of birth must both match.
      def self.find(text, dob: nil, via: ::RpmsRpc::Patient)
        text = text.to_s.strip
        return [] if text.empty?

        matches = via.lookup(text, include_inactive: true, require_response: true).map { |row| match(row) }
        dob ? matches.select { |m| m.dob == dob } : matches
      end

      def self.match(row)
        Match.new(
          dfn: row[:dfn],
          name: row[:name],
          hrn: row[:hrn].presence,
          dob: fileman_date(row[:dob]),
          dod: fileman_date(row[:dod]),
          inactive: row[:inactive] == true
        )
      end

      # AGGPTLKP writes dates as FileMan external text ("FEB 14,1910").
      def self.fileman_date(text)
        return nil if text.to_s.strip.empty?

        Date.strptime(text.to_s.strip, "%b %d,%Y")
      rescue Date::Error
        nil
      end
      private_class_method :match, :fileman_date
    end
  end
end
