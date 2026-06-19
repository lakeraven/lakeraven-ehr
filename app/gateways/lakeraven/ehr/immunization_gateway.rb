# frozen_string_literal: true

require "rpms_rpc/api/immunization"

module Lakeraven
  module EHR
    # Patient-administered immunization records.
    # Wraps RpmsRpc::Immunization (lakeraven/rpms-rpc#107) — structured
    # records via BIPC IMMLIST / BIPC IMMGET.
    class ImmunizationGateway
      def self.for_patient(dfn, via: default_provider)
        return [] if via.nil?

        via.for_patient(dfn.to_s)
      end

      def self.find(ien, via: default_provider)
        return nil if via.nil?

        via.find(ien.to_s)
      end

      def self.default_provider
        ::RpmsRpc::Immunization
      end
    end
  end
end
