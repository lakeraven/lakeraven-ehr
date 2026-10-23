# frozen_string_literal: true

require "rpms_rpc/api/reminders"

module Lakeraven
  module EHR
    # Clinical reminders as the RPMS reminder engine evaluates them for a
    # patient at a hospital location (#44). Wraps RpmsRpc::Reminders.applicable
    # (ORQQPXRM REMINDERS APPLICABLE, rpms-rpc #329). RPMS has no
    # visit-keyed reminder read, so an encounter's reminders are the ones
    # for its location. Each row's :status is :applicable, :due,
    # :not_applicable, :error or :cannot_be_determined, as the engine's due
    # flag says; not-applicable rows come back as RPMS returns them.
    class RemindersGateway
      def self.applicable(dfn, location_ien, via: default_provider)
        return [] if via.nil?
        via.applicable(dfn.to_s, location_ien&.to_s)
      end

      def self.default_provider
        ::RpmsRpc::Reminders
      end
    end
  end
end
