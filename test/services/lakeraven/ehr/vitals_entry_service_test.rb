# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class VitalsEntryServiceTest < ActiveSupport::TestCase
      setup do
        @dfn = 8791
        @visit_string = "492;3260514.09;A;2090059"
        @provider_duz = 2843
        @measurements = [
          { abbreviation: "TMP", value: 97,       units: "F" },
          { abbreviation: "PU",  value: 80,       units: "/min" },
          { abbreviation: "BP",  value: "130/90", units: "mmHg" }
        ]
      end

      def build_service(measurements, gateway:, visit_string: @visit_string, dfn: @dfn)
        VitalsEntryService.new(
          dfn: dfn, visit_string: visit_string,
          measurements: measurements, provider_duz: @provider_duz,
          gateway: gateway
        )
      end

      # === Happy path ===

      test "save succeeds with hydrated measurements when gateway returns success" do
        gw = FakeGateway.new(:add, { success: true, raw: "0" })
        result = build_service(@measurements, gateway: gw).save
        assert result.success?, "Expected success; got #{result.error.inspect}"
        assert_equal 3, result.measurements.length
      end

      test "save forwards dfn, visit_string, measurements, and provider_duz to the gateway" do
        gw = FakeGateway.new(:add, { success: true })
        build_service(@measurements, gateway: gw).save
        call = gw.calls.first
        refute_nil call
        assert_equal @dfn,          call[:args][0]
        assert_equal @visit_string, call[:args][1]
        assert_equal @measurements, call[:args][2]
        assert_equal @provider_duz, call[:kwargs][:provider_duz]
      end

      # === Validation failures ===

      test "save fails with :no_measurements when measurements is empty" do
        result = build_service([], gateway: FakeGateway.new(:add, { success: true })).save
        refute result.success?
        assert_equal :no_measurements, result.error
      end

      test "save fails with :invalid_input when visit_string is missing" do
        result = build_service(@measurements, gateway: FakeGateway.new(:add, { success: true }), visit_string: nil).save
        refute result.success?
        assert_equal :invalid_input, result.error
      end

      test "save fails with :invalid_input when dfn is missing" do
        result = build_service(@measurements, gateway: FakeGateway.new(:add, { success: true }), dfn: nil).save
        refute result.success?
        assert_equal :invalid_input, result.error
      end

      # === Gateway error surfacing ===

      test "save fails with :gateway_error when gateway returns success=false" do
        gw = FakeGateway.new(:add, { success: false, raw: "1^bad request" })
        result = build_service(@measurements, gateway: gw).save
        refute result.success?
        assert_equal :gateway_error, result.error
      end

      test "save fails with :gateway_error when gateway returns nil instead of raising" do
        gw = FakeGateway.new(:add, nil)
        result = build_service(@measurements, gateway: gw).save
        refute result.success?
        assert_equal :gateway_error, result.error
      end

      test "save fails with :gateway_error when gateway returns a non-hash" do
        gw = FakeGateway.new(:add, "0")
        result = build_service(@measurements, gateway: gw).save
        refute result.success?
        assert_equal :gateway_error, result.error
      end

      # === Production VitalGateway is never mutated by tests ===

      test "constructor-injected gateway means production VitalGateway is untouched" do
        assert VitalGateway.respond_to?(:add)
        original_owner = VitalGateway.singleton_class.instance_method(:add).owner
        build_service(@measurements, gateway: FakeGateway.new(:add, { success: true })).save
        assert_equal original_owner, VitalGateway.singleton_class.instance_method(:add).owner,
                     "VitalGateway.add ownership must not change"
      end
    end
  end
end
