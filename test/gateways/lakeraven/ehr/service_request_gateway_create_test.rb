# frozen_string_literal: true

require "test_helper"

# Tests for ServiceRequestGateway#create — referral create via BGOREF SET.
# Sits alongside the existing for_patient/delete/cancel tests.
module Lakeraven
  module EHR
    class ServiceRequestGatewayCreateTest < ActiveSupport::TestCase
      test "create returns success with the saved IEN when the RPC returns an IEN" do
        RpmsRpc.client.seed_scalar(:referral_create, "1", "5050")

        result = ServiceRequestGateway.create(1, {
          provider_ien: 99999,
          specialty: "Cardiology",
          reason: "Chest pain workup",
          priority: "ROUTINE",
          requested_date: Date.new(2026, 6, 1)
        })

        assert result[:success]
        assert_equal 5050, result[:ien]
      end

      test "create coerces an integer dfn to a string" do
        RpmsRpc.client.seed_scalar(:referral_create, "1", "5051")

        result = ServiceRequestGateway.create(1, { specialty: "Cardiology" })

        assert result[:success]
        assert_equal 5051, result[:ien]
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
