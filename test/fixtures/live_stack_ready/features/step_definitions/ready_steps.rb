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
