# frozen_string_literal: true

require "test_helper"

# Tests for MeasurementGateway — PCC measurement entry.
# Wraps RpmsRpc::Measurement (lakeraven/rpms-rpc#67). Distinct from
# clinical vitals (VitalGateway / BEHOVM); measurements are typed observations
# (height, weight, BMI, head circumference, etc.).
module Lakeraven
  module EHR
    class MeasurementGatewayTest < ActiveSupport::TestCase
      class FakeMeasurementAPI
        attr_reader :calls

        def initialize(returns:)
          @returns = returns
          @calls = []
        end

        def add(dfn, visit_ien, measurement_type, value, **opts)
          @calls << { dfn:, visit_ien:, measurement_type:, value:, opts: }
          @returns
        end
      end

      test "add returns failure shape when no provider is available" do
        result = MeasurementGateway.add(1, 2090061, "WT", 75, units: "kg", via: nil)
        assert_equal({ success: false, ien: nil, raw: nil }, result)
      end

      test "add delegates with identifiers coerced to strings and value passed through" do
        fake = FakeMeasurementAPI.new(returns: { success: true, ien: 23, raw: "23" })

        result = MeasurementGateway.add(1, 2090061, "WT", 75.5,
          units: "kg",
          qualifier: "STANDING",
          via: fake)

        assert_equal({ success: true, ien: 23, raw: "23" }, result)
        call = fake.calls.first
        assert_equal "1", call[:dfn]
        assert_equal "2090061", call[:visit_ien]
        assert_equal "WT", call[:measurement_type]
        assert_in_delta 75.5, call[:value], 0.0001
        assert_equal "kg", call[:opts][:units]
        assert_equal "STANDING", call[:opts][:qualifier]
      end

      test "default_provider is RpmsRpc::Measurement" do
        assert_equal ::RpmsRpc::Measurement, MeasurementGateway.default_provider
      end
    end
  end
end
