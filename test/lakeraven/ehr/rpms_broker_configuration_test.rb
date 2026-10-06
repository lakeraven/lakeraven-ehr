# frozen_string_literal: true

require "test_helper"

# The engine builds its broker client from the environment at boot (#539).
# Before this, nothing built one: every live request raised NotConfiguredError.
class RpmsBrokerConfigurationTest < ActiveSupport::TestCase
  setup do
    @previous_client = RpmsRpc.configuration.client
    RpmsRpc.configure { |c| c.client = nil }
  end

  teardown do
    RpmsRpc.configure { |c| c.client = @previous_client }
  end

  test "VISTA_BROKER=cia builds a CIA client for the named host and port, unconnected" do
    Lakeraven::EHR::Engine.configure_rpms_broker!(
      { "VISTA_BROKER" => "cia", "VISTA_RPC_HOST" => "10.0.0.5", "VISTA_RPC_PORT" => "19200" }
    )

    client = RpmsRpc.configuration.client
    assert_instance_of RpmsRpc::CiaClient, client
    assert_equal "10.0.0.5", client.host
    assert_equal 19200, client.port
    refute client.connected?, "boot must not open a socket; sign-on connects"
  end

  test "VISTA_BROKER=xwb builds an XWB client" do
    Lakeraven::EHR::Engine.configure_rpms_broker!(
      { "VISTA_BROKER" => "xwb", "VISTA_RPC_HOST" => "10.0.0.5", "VISTA_RPC_PORT" => "9100" }
    )

    assert_instance_of RpmsRpc::XwbClient, RpmsRpc.configuration.client
  end

  test "no VISTA_RPC_HOST, no client, and the log says no backend is configured" do
    log = StringIO.new
    Lakeraven::EHR::Engine.configure_rpms_broker!({ "VISTA_BROKER" => "cia" }, logger: Logger.new(log))

    assert_nil RpmsRpc.configuration.client
    assert_includes log.string, "No RPMS backend configured"
  end

  test "a client configured elsewhere is not reported as missing" do
    log = StringIO.new
    RpmsRpc.configure { |c| c.client = Object.new }

    Lakeraven::EHR::Engine.configure_rpms_broker!({}, logger: Logger.new(log))

    assert_empty log.string
  end

  test "a client something else configured first (the mock, a host app) is left alone" do
    existing = Object.new
    RpmsRpc.configure { |c| c.client = existing }

    Lakeraven::EHR::Engine.configure_rpms_broker!(
      { "VISTA_BROKER" => "cia", "VISTA_RPC_HOST" => "10.0.0.5", "VISTA_RPC_PORT" => "19200" }
    )

    assert_same existing, RpmsRpc.configuration.client
  end
end
