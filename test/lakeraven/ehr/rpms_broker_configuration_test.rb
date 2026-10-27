# frozen_string_literal: true

require "test_helper"

# The engine builds its broker client at boot from the host app's
# config/rpms.yml (#539). Before this, nothing built one: every live request
# raised NotConfiguredError.
class RpmsBrokerConfigurationTest < ActiveSupport::TestCase
  setup do
    @previous_client = RpmsRpc.configuration.client
    RpmsRpc.configure { |c| c.client = nil }
  end

  teardown do
    RpmsRpc.configure { |c| c.client = @previous_client }
  end

  test "broker cia builds a CIA client for the named host and port, unconnected" do
    Lakeraven::EHR::Engine.configure_rpms_broker!({ broker: "cia", host: "10.0.0.5", port: 19200 })

    client = RpmsRpc.configuration.client
    assert_instance_of RpmsRpc::CiaClient, client
    assert_equal "10.0.0.5", client.host
    assert_equal 19200, client.port
    refute client.connected?, "boot must not open a socket; sign-on connects"
  end

  test "broker xwb builds an XWB client" do
    Lakeraven::EHR::Engine.configure_rpms_broker!({ broker: "xwb", host: "10.0.0.5", port: 9100 })

    assert_instance_of RpmsRpc::XwbClient, RpmsRpc.configuration.client
  end

  test "no host, no client, and the log says no backend is configured" do
    log = StringIO.new
    Lakeraven::EHR::Engine.configure_rpms_broker!({ broker: "cia" }, logger: Logger.new(log))

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

    Lakeraven::EHR::Engine.configure_rpms_broker!({ broker: "cia", host: "10.0.0.5", port: 19200 })

    assert_same existing, RpmsRpc.configuration.client
  end

  test "the dummy app's config/rpms.yml takes the broker from VISTA_* in the environment" do
    with_env("VISTA_BROKER" => "xwb", "VISTA_RPC_HOST" => "10.0.0.9", "VISTA_RPC_PORT" => "9200") do
      settings = Lakeraven::EHR::Engine.rpms_settings

      assert_equal({ broker: "xwb", host: "10.0.0.9", port: 9200 }, settings.slice(:broker, :host, :port))
    end
  end

  test "the dummy app's test environment names no broker by default" do
    with_env("VISTA_BROKER" => nil, "VISTA_RPC_HOST" => nil, "VISTA_RPC_PORT" => nil) do
      assert_empty Lakeraven::EHR::Engine.rpms_settings[:host].to_s
    end
  end

  test "a host YAML would read as a boolean stays a hostname" do
    with_env("VISTA_RPC_HOST" => "on") do
      assert_equal "on", Lakeraven::EHR::Engine.rpms_settings[:host]
    end
  end

  private

  def with_env(vars)
    previous = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end
end
