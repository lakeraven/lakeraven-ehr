# frozen_string_literal: true

begin
  require "rpms_rpc/api/health_factor"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::HealthFactor.
end

module Lakeraven
  module EHR
    # IHS-specific structured observation entry against an open encounter.
    # Wraps RpmsRpc::HealthFactor (lakeraven/rpms-rpc#65).
    class HealthFactorGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.add(dfn, visit_ien, factor_code, level:, narrative: nil, via: default_provider)
        return FAILURE if via.nil?

        via.add(dfn.to_s, visit_ien.to_s, factor_code,
          level: level, narrative: narrative)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::HealthFactor) &&
                          ::RpmsRpc::HealthFactor.respond_to?(:add)
        ::RpmsRpc::HealthFactor
      end
    end
  end
end
