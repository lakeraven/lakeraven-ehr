# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BackendRegistryTest < ActiveSupport::TestCase
      include BrokerStubbing

      teardown do
        BackendRegistry.unregister(:test_double)
        Lakeraven::EHR.configuration.backend = :rpms
      end

      test "the configured backend is rpms unless a deployment names another" do
        assert_equal :rpms, Configuration.new.backend
      end

      test "the rpms backend's client is the client rpms-rpc is configured with" do
        fake = FakeBroker.new

        use_broker(fake) { assert_same fake, BackendRegistry.current.client }
      end

      test "the rpms backend provides every IHS-only feature" do
        BackendRegistry::CAPABILITIES.each do |capability|
          assert BackendRegistry.current.provides?(capability), "rpms should provide #{capability}"
        end
      end

      test "a backend name is matched without regard to case or padding" do
        Lakeraven::EHR.configuration.backend = " RPMS "

        assert_same BackendRegistry.fetch(:rpms), BackendRegistry.current
      end

      test "gateways call the client of whichever backend is configured" do
        rpms_side = FakeBroker.new
        other = FakeBroker.new.on("ORWPT APPTLST", [])
        BackendRegistry.register(:test_double, client: -> { other }, capabilities: [])
        Lakeraven::EHR.configuration.backend = :test_double

        use_broker(rpms_side) { RpcSupport.broker.call_rpc("ORWPT APPTLST", "42") }

        assert_equal 1, other.calls_for("ORWPT APPTLST").size
        assert_empty rpms_side.calls
      end

      test "a backend without a capability says so" do
        BackendRegistry.register(:test_double, client: -> { FakeBroker.new }, capabilities: [ :pcc_screens ])
        backend = BackendRegistry.fetch(:test_double)

        assert backend.provides?(:pcc_screens)
        assert_not backend.provides?(:prc_referrals)
      end

      # Fail closed: a mistyped or unregistered backend never falls back to
      # RPMS, and no call reaches any client.
      test "an unknown backend name raises instead of falling back to rpms" do
        fake = FakeBroker.new
        Lakeraven::EHR.configuration.backend = :vista

        use_broker(fake) do
          error = assert_raises(BackendRegistry::UnknownBackendError) { RpcSupport.broker }
          assert_match(/:vista/, error.message)
        end
        assert_empty fake.calls
      end

      # A capability name nobody defined is a typo, not a missing feature;
      # answering false would hide a working feature without a trace.
      test "an unknown capability raises when asked or registered" do
        assert_raises(BackendRegistry::UnknownCapabilityError) { BackendRegistry.current.provides?(:prc_referral) }
        assert_raises(BackendRegistry::UnknownCapabilityError) do
          BackendRegistry.register(:test_double, client: -> { FakeBroker.new }, capabilities: [ :dental ])
        end
      end
    end
  end
end
