# frozen_string_literal: true

require "test_helper"

# Tests for ServiceRequestGateway#create.
#
# rpms-rpc 0.3.0 (#235) REMOVED the fabricated create path: RpmsRpc::Referral.create
# now returns { error: :not_implemented } because BGOREF SET writes referral
# REFUSALS, not referrals — the faithful create is BMC ADD REFERRAL
# (SETREFRL^BMCRPC2 = Referral.add) with the full RCIS parameter list. Wiring
# the gateway to Referral.add is tracked in #521 and is out of Sprint 1
# (BH-only) scope. Until then the gateway surfaces the honest not-implemented
# result rather than fabricating a saved IEN.
module Lakeraven
  module EHR
    class ServiceRequestGatewayCreateTest < ActiveSupport::TestCase
      test "create surfaces the not-implemented result rather than fabricating an IEN" do
        # The old :referral_create (BGOREF SET) path is gone; create must not
        # pretend to have saved a referral it did not.
        result = ServiceRequestGateway.create(1, {
          provider_ien: 99999,
          specialty: "Cardiology",
          reason: "Chest pain workup",
          priority: "ROUTINE",
          requested_date: Date.new(2026, 6, 1)
        })

        refute result[:success]
        assert_equal :not_implemented, result[:error]
        assert_nil result[:ien]
      end

      test "create still coerces and validates its arguments" do
        result = ServiceRequestGateway.create(1, { specialty: "Cardiology" })

        refute result[:success]
        assert_equal :not_implemented, result[:error]
      end

      test "create returns failure for nil dfn" do
        result = ServiceRequestGateway.create(nil, { specialty: "Cardiology" })

        refute result[:success]
        assert_nil result[:ien]
      end

      test "create raises ArgumentError when params is not a Hash" do
        assert_raises(ArgumentError) { ServiceRequestGateway.create(1, "not a hash") }
      end
    end
  end
end
