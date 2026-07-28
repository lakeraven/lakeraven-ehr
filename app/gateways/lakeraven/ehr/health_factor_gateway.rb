# frozen_string_literal: true

require "rpms_rpc/api/health_factor"

module Lakeraven
  module EHR
    # IHS-specific structured observation entry against an open encounter.
    # Wraps RpmsRpc::HealthFactor
    class HealthFactorGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.add(dfn, visit_ien, factor_code, level:, narrative: nil, via: default_provider)
        return FAILURE if via.nil?

        via.add(dfn.to_s, visit_ien.to_s, factor_code,
          level: level, narrative: narrative)
      end

      def self.default_provider
        ::RpmsRpc::HealthFactor
      end
    end
  end
end
