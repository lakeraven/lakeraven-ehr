# frozen_string_literal: true

# SPIKE-ONLY, dev + SPIKE_MOCK_RPC-gated. Not a production path.
#
# Installs the engine's stand-in for RPMS (test/support/rpms_stand_in.rb) so
# `bin/rails server` can serve the read-only patient chart (issue #452), HTML
# and FHIR Bundle, without a live RPMS broker. Demographics AND clinical data for DFN 1 come from the
# shared synthetic seed set in test/dummy/lib/lakeraven_demo_seeds.rb, which
# the chart request test reuses so dev and test stay in lockstep.
#
# The chart itself is AUTHENTICATED. For a token-free local demo, also set
# CHART_DEMO_OPEN=1 (honored only in development — see ChartsController):
#
#   CHART_DEMO_OPEN=1 SPIKE_MOCK_RPC=1 bin/rails server
#   -> open http://localhost:3000/patients/1
if Rails.env.development? && ENV["SPIKE_MOCK_RPC"] == "1"
  require_relative "../../../support/rpms_stand_in"
  require_relative "../../lib/lakeraven_demo_seeds"

  RpmsStandIn.install! { |rpms| LakeravenDemoSeeds.seed(rpms) }

  demo = ENV["CHART_DEMO_OPEN"] == "1" ? " (CHART_DEMO_OPEN=1: chart auth bypassed for demo)" : ""
  Rails.logger.warn("[SPIKE] RPMS stood in for with synthetic seed data — NOT a real RPMS connection#{demo}")
end
