# frozen_string_literal: true

# A cucumber project of its own (no Rails, no broker) that loads the repo's
# real ready-path hooks, features/support/live_stack.rb and gateway_stubs.rb,
# over a fake broker client (#962). It stands where test/test_helper.rb stands
# in a ready `cucumber --profile stack` run: a ready LIVE_STACK, the persona's
# LIVE_STACK_CLIENT, and the watches installed by the same LiveStack.install!
# test_helper calls (so the real RpmsRpc::MockClient and Module are watched in
# this process, as in a ready run). The persona's DUZ is synthetic and there
# are no codes here at all.
# Run by test/lib/live_stack_ready_cucumber_test.rb.
require "rpms_rpc"
require "rpms_rpc/client"
require "rpms_rpc/mock_client"

REPO_ROOT = File.expand_path("../../../../..", __dir__)
require File.join(REPO_ROOT, "test/support/live_stack")

module LiveStackReady
  PERSONA_DUZ = "4321"
  OTHER_DUZ = "1"

  # Answers call_rpc with its arguments, or raises what a step set.
  class FakeClient
    attr_accessor :duz, :raises

    def initialize(duz)
      @duz = duz
    end

    def call_rpc(rpc_name, *params)
      raise @raises if @raises

      [ rpc_name, *params ]
    end
  end

  # What a gateway stub is installed on.
  class ThrowawayGateway
    def self.find(_ien) = :from_the_stack
  end
end

LIVE_STACK = LiveStack::Status.new(nil, LiveStackReady::PERSONA_DUZ)
LIVE_STACK_CLIENT = LiveStackReady::FakeClient.new(LiveStackReady::PERSONA_DUZ)
LiveStack.install!(client: LIVE_STACK_CLIENT, persona_duz: LIVE_STACK.persona_duz)
RpmsRpc.configure { |c| c.client = LIVE_STACK_CLIENT }

require File.join(REPO_ROOT, "features/support/live_stack")
require File.join(REPO_ROOT, "features/support/gateway_stubs")
