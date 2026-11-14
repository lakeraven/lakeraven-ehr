# frozen_string_literal: true

When("the persona reads from the stack") do
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
end

When("nothing is read") do
  # No RPC at all.
end

When("the stack refuses an RPC") do
  LIVE_STACK_CLIENT.raises = RpmsRpc::Client::RpcRefusedError.new("refused")
  RpmsRpc.configuration.client.call_rpc("ORWPT LIST ALL", "A", 1)
end

When("the app swallows a refused RPC") do
  LIVE_STACK_CLIENT.raises = RpmsRpc::Client::RpcRefusedError.new("refused")
  begin
    RpmsRpc.configuration.client.call_rpc("ORWPT LIST ALL", "A", 1)
  rescue StandardError
    nil
  end
end

When("another client answers") do
  other = LiveStackReady::FakeClient.new(LiveStackReady::PERSONA_DUZ)
  RpmsRpc.configure { |c| c.client = other }
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
end

When("the client signs on as someone else") do
  LIVE_STACK_CLIENT.duz = LiveStackReady::OTHER_DUZ
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
end

When("a gateway is stubbed") do
  stub_gateway(LiveStackReady::ThrowawayGateway, :find, :from_the_stub)
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
end

# A stub installed without stub_gateway, so @gateway_stubs never hears of it.
# The After below puts the method back.
When("a gateway is stubbed bare") do
  @bare_stub_original = LiveStackReady::ThrowawayGateway.singleton_class.instance_method(:find)
  LiveStackReady::ThrowawayGateway.define_singleton_method(:find) { |_| :from_the_stub }
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
end

After do
  if @bare_stub_original
    LiveStackReady::ThrowawayGateway.singleton_class.send(:define_method, :find, @bare_stub_original)
    @bare_stub_original = nil
  end
end

# The real mock, unseeded: it answers every read path with an empty reply.
When("the mock answers through its lines") do
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
  RpmsRpc::MockClient.new.call_rpc_lines("ORWPT LIST ALL", "A", 1)
end

When("the mock answers through its global array") do
  RpmsRpc.configuration.client.call_rpc("ORWU USERINFO")
  RpmsRpc::MockClient.new.call_rpc_global_array("ORWPT LIST ALL", "A", 1)
end
