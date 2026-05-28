# frozen_string_literal: true

require "rpms_rpc/api/problem"

module Lakeraven
  module EHR
    # Engine-side gateway over RpmsRpc::Problem. The engine vocabulary is
    # "Condition" (matches FHIR / app/models/lakeraven/ehr/condition.rb); the
    # underlying RPC module is "Problem" (IPL terminology).
    class ConditionGateway
      def self.for_patient(dfn)
        RpmsRpc::Problem.for_patient(dfn.to_s)
      end

      def self.add(dfn, problem)
        RpmsRpc::Problem.add(dfn.to_s, problem)
      end

      def self.update(dfn, ien, changes)
        RpmsRpc::Problem.update(dfn.to_s, ien.to_s, changes)
      end

      def self.delete(dfn, ien, reason:)
        RpmsRpc::Problem.delete(dfn.to_s, ien.to_s, reason: reason)
      end

      def self.filter(dfn, scope:)
        RpmsRpc::Problem.filter(dfn.to_s, scope: scope)
      end
    end
  end
end
