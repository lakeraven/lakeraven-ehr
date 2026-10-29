# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # Shared behavioural contract for LocalAdapter and MockAdapter.
      module AdapterContract
        VALUESET_ID = "gpra-bgpmu-diabetes-dx"
        ICD9_SYSTEM = "http://hl7.org/fhir/sid/icd-9-cm"
        ICD10_SYSTEM = "http://hl7.org/fhir/sid/icd-10-cm"
        SAMPLE_CODE = "250.00"
        MISSING_ID = "non-existent-valueset"

        def assert_adapter_contract(adapter)
          codes = adapter.expand_valueset(VALUESET_ID)
          assert_kind_of Array, codes
          assert codes.any? { |c| c[:code] == SAMPLE_CODE && c[:system] == ICD9_SYSTEM }

          valueset = adapter.get_valueset(VALUESET_ID)
          assert_equal "ValueSet", valueset["resourceType"]
          assert_equal VALUESET_ID, valueset["id"]

          listed = adapter.list_valuesets
          assert listed.any? { |vs| (vs["id"] || vs["name"]) == VALUESET_ID }

          search_hits = adapter.search("diabetes")
          assert search_hits.any? { |vs| vs["title"]&.downcase&.include?("diabetes") }

          lookup = adapter.lookup_code(ICD9_SYSTEM, SAMPLE_CODE)
          assert_equal ICD9_SYSTEM, lookup[:system]
          assert_equal SAMPLE_CODE, lookup[:code]
          assert lookup[:display].present?

          assert adapter.validate_code(ICD9_SYSTEM, SAMPLE_CODE, valueset_id: VALUESET_ID)
          refute adapter.validate_code(ICD9_SYSTEM, "INVALID-CODE", valueset_id: VALUESET_ID)

          assert_raises(TerminologyService::ValueSetNotFoundError) do
            adapter.expand_valueset(MISSING_ID)
          end
          assert_raises(TerminologyService::ValueSetNotFoundError) do
            adapter.validate_code(ICD9_SYSTEM, SAMPLE_CODE, valueset_id: MISSING_ID)
          end
        end
      end
    end
  end
end
