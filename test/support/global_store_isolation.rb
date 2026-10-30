# frozen_string_literal: true

# Process-global in-memory stores survive from one example to the next unless
# something clears them. Reset the whole list before every example.
module GlobalStoreIsolation
  # Any new process-global in-memory store must be added here.
  # BASELINE_MOCK_SEEDS is defined in test/test_helper.rb; the proc looks it
  # up when reset! runs, after that constant exists.
  STORE_RESETS = [
    -> { Lakeraven::EHR::AssertionReplayGuard.reset! },
    -> { Lakeraven::EHR::ProvenanceStore.reset_instance! },
    -> { Lakeraven::EHR::ExportsController.reset_store! },
    -> { Lakeraven::EHR::LoginThrottle.reset! },
    # The per-user RPMS connection pool (#585), once the engine has one.
    -> { Lakeraven::EHR::RpmsSessions.reset! if defined?(Lakeraven::EHR::RpmsSessions) },
    -> { Lakeraven::EHR::ClinicalDecisionSupportService.rule_overrides.clear },
    -> { Lakeraven::EHR::EncounterStore.reset_instance! },
    -> { Lakeraven::EHR::MedicationStore.reset_instance! },
    -> { Lakeraven::EHR::CarePlanStore.reset_instance! },
    -> { Lakeraven::EHR::DiagnosticReportStore.reset_instance! },
    -> { RpmsRpc.mock!(&BASELINE_MOCK_SEEDS) unless LIVE_RPMS }
  ].freeze

  def self.reset!
    STORE_RESETS.each(&:call)
  end

  def self.included(base)
    base.setup { GlobalStoreIsolation.reset! }
  end
end
