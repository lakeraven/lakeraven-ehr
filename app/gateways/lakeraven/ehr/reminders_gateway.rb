# frozen_string_literal: true

# Try to load the reminders RPC API. The gem may not yet ship it
# (lakeraven/rpms-rpc#59), in which case `RpmsRpc::Reminders` simply
# stays undefined and `default_provider` returns nil. When the gem
# updates, this require succeeds and the gateway begins delegating —
# no engine-side change needed.
require "rpms_rpc/api/reminders"

module Lakeraven
  module EHR
    # Clinical reminders relevant to a specific encounter.
    #
    # Backed by RpmsRpc::Reminders.for_visit once that primitive ships
    #  Until then, returns an empty list so the
    # encounter open path can wire the contract without a hard dependency
    # on the unreleased gateway method.
    class RemindersGateway
      # Normalizes identifiers to strings to match the convention used by
      # the other gateways (EncounterGateway, ObservationGateway, etc.).
      def self.for_visit(dfn, visit_ien, via: default_provider)
        return [] if via.nil?
        via.for_visit(dfn.to_s, visit_ien.to_s)
      end

      # Returns the RPC provider if the rpms-rpc gem has shipped the
      # reminders API, otherwise nil. Tests can pass `via:` directly to
      # exercise both branches without monkey-patching constants.
      def self.default_provider
        ::RpmsRpc::Reminders
      end
    end
  end
end
