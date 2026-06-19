# frozen_string_literal: true

require "rpms_rpc/api/reminders"

module Lakeraven
  module EHR
    # Clinical reminders relevant to a specific encounter.
    # Wraps RpmsRpc::Reminders.for_visit.
    class RemindersGateway
      def self.for_visit(dfn, visit_ien, via: default_provider)
        return [] if via.nil?
        via.for_visit(dfn.to_s, visit_ien.to_s)
      end

      def self.default_provider
        ::RpmsRpc::Reminders
      end
    end
  end
end
