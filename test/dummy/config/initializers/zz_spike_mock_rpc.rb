# frozen_string_literal: true

# SPIKE-ONLY, dev + SPIKE_MOCK_RPC-gated. Not a production path.
#
# Seeds RpmsRpc's in-memory mock client so `bin/rails server` can serve the
# read-only patient chart (issue #452) — HTML + FHIR Bundle — without a live
# RPMS/VistA broker. Demographics AND clinical data for DFN 1 come from the
# shared synthetic seed set in test/dummy/lib/lakeraven_demo_seeds.rb, which
# the chart request test reuses so dev and test stay in lockstep.
if Rails.env.development? && ENV["SPIKE_MOCK_RPC"] == "1"
  require "rpms_rpc/version"
  require "rpms_rpc/mock_client"
  require_relative "../../lib/lakeraven_demo_seeds"

  RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }

  Rails.logger.warn("[SPIKE] RpmsRpc mocked with synthetic seed data — NOT a real RPMS connection")
end
