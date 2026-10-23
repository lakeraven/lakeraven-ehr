# frozen_string_literal: true

require "rpms_rpc/api/immunization"

module Lakeraven
  module EHR
    # Patient-administered immunization records. Wraps RpmsRpc::Immunization,
    # which reads V IMMUNIZATION through BGOVIMM GET (rpms-rpc #378; the BIPC
    # IMMLIST / IMMGET names it once sent were registered nowhere).
    #
    # BGOVIMM GET returns no status, CVX code, route or VFC fields. Every row
    # it returns is a V IMMUNIZATION entry, a dose given (a refusal is filed
    # elsewhere, see ImmunizationRefusalGateway), so a row with no status of
    # its own is "completed". The vaccine is named by display text only.
    class ImmunizationGateway
      ADMINISTERED = { status: "completed" }.freeze

      def self.for_patient(dfn, via: default_provider)
        return [] if via.nil?

        Array(via.for_patient(dfn.to_s)).map { |row| ADMINISTERED.merge(row) }
      end

      def self.find(ien, via: default_provider)
        return nil if via.nil?

        row = via.find(ien.to_s)
        row && ADMINISTERED.merge(row)
      end

      def self.default_provider
        ::RpmsRpc::Immunization
      end
    end
  end
end
