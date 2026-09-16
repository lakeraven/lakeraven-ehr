# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/client"

module Lakeraven
  module EHR
    # Engine-local reads are not the whole of PHI access. The consequential
    # acts go OUT — to RPMS, on a user's behalf — and an audit that stops at
    # the engine's own database cannot say what was done to the chart of
    # record.
    class AuditedBrokerTest < ActiveSupport::TestCase
      include BrokerStubbing

      setup do
        AuditEvent.delete_all
        AuditContext.reset
      end

      teardown { AuditContext.reset }

      test "an RPC executed against the backend leaves its own record" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        use_broker(fake) { RpcSupport.broker.call_rpc("ORWPT ID INFO", "1") }

        event = AuditEvent.order(:id).last
        refute_nil event, "an action against the RPMS backend left no audit trail"
        assert_equal "E", event.action
        assert_equal "ORWPT ID INFO", event.entity_identifier
        assert_equal "0", event.outcome
      end

      # Parameters are where the PHI is — a name, a date of birth, an SSN in
      # a caret-joined payload. The record says WHAT was executed, never with
      # what.
      test "the record names the RPC and never its parameters" do
        fake = FakeBroker.new.on("BSDX ADD", "1^501")

        use_broker(fake) { RpcSupport.broker.call_rpc("BSDX ADD", "SMITH,SYNTHETIC^M^2900101^000000000") }

        event = AuditEvent.order(:id).last
        serialized = event.attributes.values.compact.map(&:to_s).join(" ")
        refute_includes serialized, "SMITH,SYNTHETIC", "the audit row carried the RPC parameters"
        refute_includes serialized, "000000000"
      end

      test "an RPC the broker could not complete is recorded as a failure" do
        fake = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("broker unreachable"))

        use_broker(fake) do
          assert_raises(RpmsRpc::Client::ConnectionError) { RpcSupport.broker.call_rpc("ORWPT ID INFO", "1") }
        end

        event = AuditEvent.order(:id).last
        refute_nil event, "a failed backend action left no audit trail"
        assert_equal "8", event.outcome
      end

      # Same rule as the HTTP boundary: if it cannot be written down, it did
      # not happen — the caller does not get the result.
      test "an RPC whose audit cannot be written does not return a result" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^SECRET")

        with_broken_audit do
          use_broker(fake) do
            assert_raises(AuditedBroker::UnrecordedAccessError) do
              RpcSupport.broker.call_rpc("ORWPT ID INFO", "1")
            end
          end
        end
      end

      # A backend action with nobody to answer for it is recorded as having
      # nobody to answer for it.
      test "outside a request the actor is unattributed, not guessed" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        use_broker(fake) { RpcSupport.broker.call_rpc("ORWPT ID INFO", "1") }

        event = AuditEvent.order(:id).last
        assert_equal "Unknown", event.agent_who_type
        assert_nil event.agent_who_identifier
      end

      test "inside an audited request the backend action names the same human" do
        AuditContext.agent_resolver = -> { { agent_who_type: "Practitioner", agent_who_identifier: "301" } }
        AuditContext.network_address = "10.0.0.9"
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        use_broker(fake) { RpcSupport.broker.call_rpc("ORWPT ID INFO", "1") }

        event = AuditEvent.order(:id).last
        assert_equal "Practitioner", event.agent_who_type
        assert_equal "301", event.agent_who_identifier
        assert_equal "10.0.0.9", event.agent_network_address
      end

      # F3's survival tests live in AuditedBrokerDetachedTest — they must run
      # OUTSIDE the transactional-test wrapper, because the wrapper pins the
      # connection and the detached write deliberately degrades to inline
      # there (see AuditEvent.create_detached!).

      test "wrapping an already-wrapped broker does not double-record" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        use_broker(fake) do
          AuditedBroker.wrap(AuditedBroker.wrap(RpmsRpc.client)).call_rpc("ORWPT ID INFO", "1")
        end

        assert_equal 1, AuditEvent.count
      end

      test "the wrapper still answers the allowlisted capability questions" do
        fake = FakeBroker.new

        use_broker(fake) do
          assert RpcSupport.broker.supports?(:anything)
        end
      end

      # THE BLIND-MOCK FINDING (S6): both production clients expose a public
      # `call_rpc_raw` that executes an RPC, and `method_missing` forwarded it
      # straight past the audit. The suite could not see it because
      # FakeBroker implemented only `call_rpc` — a mock that cannot express a
      # failure is not evidence against it. FakeBroker now carries the real
      # client's surface, and the wrapper refuses to forward anything that
      # can execute against the backend.
      test "call_rpc_raw cannot walk past the audit" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^SECRET")

        use_broker(fake) do
          assert_raises(NoMethodError) { RpcSupport.broker.call_rpc_raw("ORWPT ID INFO", "1") }
        end

        assert_empty fake.calls, "the RPC executed against the backend without a row"
        assert_equal 0, AuditEvent.count
      end

      test "nothing outside the allowlist passes through, even when the client answers it" do
        fake = FakeBroker.new

        use_broker(fake) do
          broker = RpcSupport.broker
          assert fake.respond_to?(:call_rpc_raw), "the fake no longer models the real client's surface"
          refute_respond_to broker, :call_rpc_raw
          assert_raises(NoMethodError) { broker.read_response }
          assert_raises(NoMethodError) { broker.calls_for("ORWPT ID INFO") }
        end
      end

      private

      def with_broken_audit
        AuditEvent.define_singleton_method(:create!) do |*|
          raise ActiveRecord::StatementInvalid, "audit store unavailable"
        end
        yield
      ensure
        AuditEvent.singleton_class.send(:remove_method, :create!)
      end
    end
  end
end
