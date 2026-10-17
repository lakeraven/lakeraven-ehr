# frozen_string_literal: true

# Scenarios seed the same process-global stores as minitest (provenance
# records, bulk exports, login attempts, CDS rule overrides). Reset before
# every scenario so one scenario cannot leak into the next.
Before { GlobalStoreIsolation.reset! }
