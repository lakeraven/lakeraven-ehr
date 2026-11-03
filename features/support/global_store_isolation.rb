# frozen_string_literal: true

require_relative "rpms_demo_site"

# Scenarios seed the same process-global stores as minitest (provenance
# records, bulk exports, login attempts, CDS rule overrides). Reset before
# every scenario so one scenario cannot leak into the next. On a mock run the
# reset mock is then given the demo site, in this one hook so the order is
# explicit (Cucumber's support-file load order is not).
Before do
  GlobalStoreIsolation.reset!
  RpmsDemoSite.seed!(RpmsRpc.client) unless LIVE_RPMS
end
