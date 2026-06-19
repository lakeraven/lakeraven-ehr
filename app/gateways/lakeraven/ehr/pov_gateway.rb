# frozen_string_literal: true

require "rpms_rpc/api/pov"

module Lakeraven
  module EHR
    # Visit purpose-of-visit (diagnosis) entry against an open encounter.
    # Wraps RpmsRpc::Pov 
    class PovGateway
      FAILURE = { success: false, ien: nil, raw: nil }.freeze

      def self.add(dfn, visit_ien, diagnosis_code, narrative:, modifiers: {}, via: default_provider)
        return FAILURE if via.nil?

        via.add(dfn.to_s, visit_ien.to_s, diagnosis_code,
          narrative: narrative, modifiers: modifiers)
      end

      def self.default_provider
        ::RpmsRpc::Pov
      end
    end
  end
end
