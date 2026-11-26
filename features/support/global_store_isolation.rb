# frozen_string_literal: true

require_relative "rpms_demo_site"
require_relative "../../test/support/sensitive_patient_access_seeds"

# Scenarios seed the same process-global stores as minitest (provenance
# records, bulk exports, login attempts, CDS rule overrides). Reset before
# every scenario so one scenario cannot leak into the next. On a stand-in run
# the reset stand-in is then given the demo site, in this one hook so the order
# is explicit (Cucumber's support-file load order is not).
Before do
  GlobalStoreIsolation.reset!
  unless LIVE_RPMS
    RpmsDemoSite.stand_in!(RpmsStandIn)
    # The demo site's patients, too, answer the sensitive-record check (#613)
    # with 0, not sensitive. Scenarios about the check answer over it.
    SensitivePatientAccessSeeds.seed_demo_patients_not_sensitive!
  end
end
