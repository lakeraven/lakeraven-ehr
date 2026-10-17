# frozen_string_literal: true

require "test_helper"

# Process-global singletons (provenance, bulk exports, login throttle, CDS
# overrides, RpmsRpc mock seeds) survive from one example to the next unless
# the suite resets them. i_suck_and_my_tests_are_order_dependent! runs
# examples alphabetically so test_2 always follows test_1.
module GlobalStoreIsolationTestHelpers
  ISOLATION_THROTTLE_KEY = "isolation-throttle-synthetic-key"
  ISOLATION_CDS_RULE = "isolation_synthetic_cds_rule"
  ISOLATION_REFERRAL_IEN = "ISOLATION-LEAK-589"
  BASELINE_PATIENT_DFN = 1
  BASELINE_PATIENT_NAME = "Anderson,Alice"

  module_function

  def seed_process_global_state!(provenance_target_id:)
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: provenance_target_id, activity: "CREATE",
        agent_who_id: "synthetic-agent", agent_who_type: "Practitioner", recorded: Time.current
      )
    )

    export = Lakeraven::EHR::BulkExport.new(
      id: "isolation-leak-export-#{provenance_target_id}", export_type: "patient", status: "pending",
      request_url: "https://example.test/exports",
      output_format: "application/fhir+ndjson", client_id: "synthetic-client"
    )
    Lakeraven::EHR::ExportsController.store[export.id] = export

    Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS.times do
      Lakeraven::EHR::LoginThrottle.record_failure(ISOLATION_THROTTLE_KEY)
    end

    Lakeraven::EHR::ClinicalDecisionSupportService.update_rule_enabled(
      ISOLATION_CDS_RULE, false, provider_duz: "synthetic-provider"
    )

    RpmsRpc.client.seed_keyed_collection(:referral_search, BASELINE_PATIENT_DFN.to_s, [
      { ien: ISOLATION_REFERRAL_IEN, patient_dfn: BASELINE_PATIENT_DFN, status: "active", type: "C",
        date: Date.new(2026, 2, 1), provider: "SYNTHETIC,PROVIDER" }
    ])
  end

  def assert_process_global_state_present!(provenance_target_id:)
    assert Lakeraven::EHR::ProvenanceStore.instance.for_target("Patient", provenance_target_id).any?
    export_id = "isolation-leak-export-#{provenance_target_id}"
    assert Lakeraven::EHR::ExportsController.store.key?(export_id)

    assert Lakeraven::EHR::LoginThrottle.throttled?(ISOLATION_THROTTLE_KEY),
           "LoginThrottle should record synthetic failures within the same example"

    refute Lakeraven::EHR::ClinicalDecisionSupportService.rule_enabled?(ISOLATION_CDS_RULE),
           "CDS override should be visible within the same example"

    referrals = Lakeraven::EHR::ServiceRequestGateway.for_patient(BASELINE_PATIENT_DFN)
    assert referrals.any? { |row| row[:ien].to_s == ISOLATION_REFERRAL_IEN },
           "RpmsRpc mock should return the synthetic referral seed within the same example"
  end

  def assert_process_global_state_reset!(provenance_target_id:)
    assert_equal 0, Lakeraven::EHR::ProvenanceStore.instance.count,
                 "ProvenanceStore leaked a record from a prior test; suite results depend on test order"
    assert Lakeraven::EHR::ExportsController.store.empty?,
           "ExportsController.store leaked an export from a prior test; suite results depend on test order"

    refute Lakeraven::EHR::LoginThrottle.throttled?(ISOLATION_THROTTLE_KEY),
           "LoginThrottle leaked synthetic failures from a prior test; suite results depend on test order"
    assert_empty Lakeraven::EHR::ClinicalDecisionSupportService.rule_overrides,
                 "ClinicalDecisionSupportService.rule_overrides leaked from a prior test; suite results depend on test order"

    referrals = Lakeraven::EHR::ServiceRequestGateway.for_patient(BASELINE_PATIENT_DFN)
    refute referrals.any? { |row| row[:ien].to_s == ISOLATION_REFERRAL_IEN },
           "RpmsRpc mock client leaked a referral_search seed from a prior test; suite results depend on test order"

    patient = Lakeraven::EHR::PatientGateway.find(BASELINE_PATIENT_DFN)
    assert_not_nil patient,
                   "Baseline mock patient seed was wiped by an over-broad reset; suite results depend on test order"
    assert_equal BASELINE_PATIENT_NAME, patient.name,
                 "Baseline mock patient_select seed was wiped by an over-broad reset; suite results depend on test order"
  end
end

class GlobalStoreIsolationUnitTest < ActiveSupport::TestCase
  include GlobalStoreIsolationTestHelpers
  i_suck_and_my_tests_are_order_dependent!

  def test_1_a_test_leaves_records_in_process_global_stores
    seed_process_global_state!(provenance_target_id: "rpms-isolation-unit")
    assert_process_global_state_present!(provenance_target_id: "rpms-isolation-unit")
  end

  def test_2_the_next_test_starts_with_reset_process_global_stores
    assert_process_global_state_reset!(provenance_target_id: "rpms-isolation-unit")
  end
end

class GlobalStoreIsolationIntegrationTest < ActionDispatch::IntegrationTest
  include GlobalStoreIsolationTestHelpers
  i_suck_and_my_tests_are_order_dependent!

  def test_1_a_test_leaves_records_in_process_global_stores
    seed_process_global_state!(provenance_target_id: "rpms-isolation-integration")
    assert_process_global_state_present!(provenance_target_id: "rpms-isolation-integration")
  end

  def test_2_the_next_test_starts_with_reset_process_global_stores
    assert_process_global_state_reset!(provenance_target_id: "rpms-isolation-integration")
  end
end
