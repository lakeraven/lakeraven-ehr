# frozen_string_literal: true

module Lakeraven
  module EHR
    # An RPMS broker that writes down what it was asked to do.
    #
    # Engine-local reads are not the whole of PHI access. The consequential
    # acts go OUT — a registration, a vitals entry, a signed note — against
    # the chart of record, on a user's behalf. An audit that stops at the
    # engine's own database cannot answer what was done to RPMS.
    #
    # WHAT IS RECORDED: the RPC name, the actor (from AuditContext, which the
    # audited HTTP request publishes), the network address, the tenant and
    # facility, and whether the call completed.
    #
    # WHAT IS NOT: the parameters. That is where the PHI is — a name, a date
    # of birth, an SSN in a caret-joined payload — and an audit log is not a
    # place to put it (ADR 0002). "WHAT was executed" is the auditable fact;
    # "with which patient's details" is already in `entity_identifier` when
    # the calling gateway knows it.
    #
    # FAIL CLOSED, the same rule as the HTTP boundary: if the call cannot be
    # written down, the caller does not get the result. Inside a controller
    # that surfaces as the audited action's 503, with the engine's own writes
    # rolled back.
    #
    # A REAL LIMIT, stated rather than papered over: this wraps the broker
    # that `RpcSupport.broker` hands out, which is the engine's declared
    # accessor for gateway broker access. Gateways calling the `RpmsRpc::*`
    # API modules directly reach the configured client without passing
    # through here; in a request those are covered at the HTTP boundary, and
    # outside one they are not covered at all. Closing that needs a client
    # hook in rpms-rpc rather than more wrappers in the engine — see the
    # follow-up issue.
    class AuditedBroker
      class UnrecordedAccessError < StandardError; end

      # An RPC is an EXECUTION against the backend. It is not classified as a
      # read or a write here: that would mean maintaining a list of which
      # wire names write, and a wrong entry in that list is a row that lies.
      # The RPC name is recorded, which says it exactly.
      AUDIT_ACTION = "E"
      ENTITY_TYPE = "RemoteProcedure"

      def self.wrap(client)
        client.is_a?(self) ? client : new(client)
      end

      def initialize(client)
        @client = client
      end

      def call_rpc(rpc_name, *params, **options, &block)
        result = @client.call_rpc(rpc_name, *params, **options, &block)
        record!(rpc_name, outcome: "0")
        result
      rescue UnrecordedAccessError
        raise
      rescue StandardError => e
        # The attempt happened whether or not it succeeded, so it is recorded
        # before the failure goes on its way.
        record_attempt(rpc_name, outcome: "8", reason: e.class.name)
        raise
      end

      # What may pass through WITHOUT a row: capability questions only.
      #
      # The first version forwarded ANYTHING the client answered — and both
      # production clients publicly answer `call_rpc_raw`, which executes an
      # RPC. That was a second door straight past the audit (S6), and the
      # suite could not see it because the test fake did not model the real
      # client's surface. The passthrough is now an explicit allowlist of
      # methods that cannot touch the backend or its credentials; everything
      # else — `call_rpc_raw`, `read_response`, `authenticate`, `connect` —
      # is refused, so a caller that needs it must come through `call_rpc`
      # and be recorded.
      PASSTHROUGH = %i[supports? connected? hostname].freeze

      def respond_to_missing?(name, include_private = false)
        (PASSTHROUGH.include?(name) && @client.respond_to?(name, include_private)) || super
      end

      def method_missing(name, *args, **options, &block)
        return super unless PASSTHROUGH.include?(name) && @client.respond_to?(name)

        @client.public_send(name, *args, **options, &block)
      end

      private

      def record!(rpc_name, outcome:, reason: nil)
        AuditEvent.create!(
          event_type: "application",
          action: AUDIT_ACTION,
          outcome: outcome,
          outcome_desc: reason,
          entity_type: ENTITY_TYPE,
          entity_identifier: rpc_name.to_s,
          **AuditContext.agent_attributes,
          agent_network_address: AuditContext.network_address,
          tenant_identifier: AuditContext.tenant_identifier,
          facility_identifier: AuditContext.facility_identifier
        )
      rescue StandardError => e
        Rails.logger.error("[audit] refusing to serve an unrecorded backend action: #{e.message}")
        raise UnrecordedAccessError,
              "#{rpc_name} could not be recorded, so its result is not being returned"
      end

      # For a call that already failed: the failure is the news, so a failed
      # audit is logged loudly rather than replacing the original exception
      # with a less informative one.
      def record_attempt(rpc_name, outcome:, reason: nil)
        record!(rpc_name, outcome: outcome, reason: reason)
      rescue UnrecordedAccessError => e
        Rails.logger.error("[audit] #{e.message}")
      end
    end
  end
end
