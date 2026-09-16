# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/client"

module Lakeraven
  module EHR
    # F3 (round-2 gate on #512, both seats): the RPC EXECUTED against RPMS —
    # a remote effect no local ROLLBACK can undo. Its row therefore must not
    # participate in the caller's transaction: when the surrounding action
    # rolls back (the concern does exactly this when an action raises),
    # "what was done to the chart of record" has to survive.
    #
    # Transactional tests are OFF here, deliberately: under the wrapper the
    # pool pins a thread-locked connection and `create_detached!` degrades to
    # an inline write, so a wrapped test would prove nothing about survival.
    # This class exercises the real detached path — a second connection whose
    # commit the caller's rollback cannot touch — and cleans up after itself.
    class AuditedBrokerDetachedTest < ActiveSupport::TestCase
      include BrokerStubbing

      self.use_transactional_tests = false

      setup do
        AuditEvent.delete_all
        AuditContext.reset
      end

      teardown do
        AuditEvent.delete_all
        AuditContext.reset
      end

      test "an executed RPC's row survives the enclosing transaction's rollback" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        use_broker(fake) do
          ActiveRecord::Base.transaction(requires_new: true) do
            RpcSupport.broker.call_rpc("ORWPT ID INFO", "1")
            raise ActiveRecord::Rollback # what audit_clinical_access does when the action raises
          end
        end

        assert_equal 1, fake.calls.size, "the probe did not execute the RPC"
        assert_equal 1, AuditEvent.where(entity_type: "RemoteProcedure").count,
          "the record of an RPC that DID execute was destroyed by a local rollback"
      end

      test "outside any transaction the detached write is a plain insert" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^ok")

        use_broker(fake) { RpcSupport.broker.call_rpc("ORWPT ID INFO", "1") }

        assert_equal 1, AuditEvent.where(entity_type: "RemoteProcedure").count
      end

      # Fail closed must hold on the detached path too: a failure inside the
      # writer thread surfaces to the caller.
      test "a detached write that fails still refuses the RPC result" do
        fake = FakeBroker.new.on("ORWPT ID INFO", "1^SECRET")
        AuditEvent.define_singleton_method(:create!) do |*|
          raise ActiveRecord::StatementInvalid, "audit store unavailable"
        end

        begin
          use_broker(fake) do
            ActiveRecord::Base.transaction(requires_new: true) do
              assert_raises(AuditedBroker::UnrecordedAccessError) do
                RpcSupport.broker.call_rpc("ORWPT ID INFO", "1")
              end
            end
          end
        ensure
          AuditEvent.singleton_class.send(:remove_method, :create!)
        end
      end
    end
  end
end
