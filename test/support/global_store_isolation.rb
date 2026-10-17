# frozen_string_literal: true

# Process-global in-memory stores survive from one example to the next unless
# something clears them. Reset the whole list before every example.
module GlobalStoreIsolation
  # Any new process-global in-memory store must be added here.
  STORE_RESETS = [
    -> { Lakeraven::EHR::ProvenanceStore.reset_instance! },
    -> { Lakeraven::EHR::ExportsController.reset_store! },
    -> { Lakeraven::EHR::LoginThrottle.reset! },
    -> { Lakeraven::EHR::ClinicalDecisionSupportService.rule_overrides.clear }
  ].freeze

  def self.reset!
    STORE_RESETS.each(&:call)
  end

  def self.included(base)
    base.setup { GlobalStoreIsolation.reset! }
  end
end
