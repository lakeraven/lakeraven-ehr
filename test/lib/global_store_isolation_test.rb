# frozen_string_literal: true

require "test_helper"

# ProvenanceStore and ExportsController.store are process-global singletons.
# i_suck_and_my_tests_are_order_dependent! runs examples alphabetically so
# test_2 always follows test_1 and proves each example starts with empty stores.
class GlobalStoreIsolationUnitTest < ActiveSupport::TestCase
  i_suck_and_my_tests_are_order_dependent!

  def test_1_a_test_leaves_records_in_the_global_stores
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "rpms-1", activity: "CREATE",
        agent_who_id: "synthetic-agent", agent_who_type: "Practitioner", recorded: Time.current
      )
    )

    export = Lakeraven::EHR::BulkExport.new(
      id: "isolation-leak-export", export_type: "patient", status: "pending",
      request_url: "https://example.test/exports",
      output_format: "application/fhir+ndjson", client_id: "synthetic-client"
    )
    Lakeraven::EHR::ExportsController.store[export.id] = export

    assert Lakeraven::EHR::ProvenanceStore.instance.for_target("Patient", "rpms-1").any?
    assert Lakeraven::EHR::ExportsController.store.key?(export.id)
  end

  def test_2_the_next_test_starts_with_empty_global_stores
    assert_equal 0, Lakeraven::EHR::ProvenanceStore.instance.count,
                 "ProvenanceStore leaked a record from a prior test; suite results depend on test order"
    assert Lakeraven::EHR::ExportsController.store.empty?,
           "ExportsController.store leaked an export from a prior test; suite results depend on test order"
  end
end

class GlobalStoreIsolationIntegrationTest < ActionDispatch::IntegrationTest
  i_suck_and_my_tests_are_order_dependent!

  def test_1_a_test_leaves_records_in_the_global_stores
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "rpms-2", activity: "CREATE",
        agent_who_id: "synthetic-agent", agent_who_type: "Practitioner", recorded: Time.current
      )
    )

    export = Lakeraven::EHR::BulkExport.new(
      id: "isolation-leak-export-integration", export_type: "patient", status: "pending",
      request_url: "https://example.test/exports",
      output_format: "application/fhir+ndjson", client_id: "synthetic-client"
    )
    Lakeraven::EHR::ExportsController.store[export.id] = export

    assert Lakeraven::EHR::ProvenanceStore.instance.for_target("Patient", "rpms-2").any?
    assert Lakeraven::EHR::ExportsController.store.key?(export.id)
  end

  def test_2_the_next_test_starts_with_empty_global_stores
    assert_equal 0, Lakeraven::EHR::ProvenanceStore.instance.count,
                 "ProvenanceStore leaked a record from a prior test; suite results depend on test order"
    assert Lakeraven::EHR::ExportsController.store.empty?,
           "ExportsController.store leaked an export from a prior test; suite results depend on test order"
  end
end
