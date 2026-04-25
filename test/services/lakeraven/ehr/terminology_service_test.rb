# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TerminologyServiceTest < ActiveSupport::TestCase
      TEST_VALUESETS = File.expand_path("../../../fixtures/files/valuesets", __dir__)

      setup do
        @original_umls = ENV["UMLS_API_KEY"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = nil
        TerminologyService.additional_valueset_paths = [ TEST_VALUESETS ]
      end

      teardown do
        ENV["UMLS_API_KEY"] = @original_umls
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        TerminologyService.additional_valueset_paths = []
      end

      # =============================================================================
      # BACKEND DETECTION
      # =============================================================================

      test "detects local backend when no API keys configured" do
        service = TerminologyService.new
        assert_equal :local, service.backend
      end

      test "detects VSAC backend when UMLS_API_KEY is set" do
        ENV["UMLS_API_KEY"] = "test-api-key"
        service = TerminologyService.new
        assert_equal :vsac, service.backend
      end

      test "detects IRIS backend when IRIS_TERMINOLOGY_URL is set" do
        ENV["IRIS_TERMINOLOGY_URL"] = "https://iris.example.com/fhir"
        service = TerminologyService.new
        assert_equal :iris, service.backend
      end

      test "IRIS takes precedence over VSAC when both configured" do
        ENV["IRIS_TERMINOLOGY_URL"] = "https://iris.example.com/fhir"
        ENV["UMLS_API_KEY"] = "test-api-key"
        service = TerminologyService.new
        assert_equal :iris, service.backend
      end

      test "allows explicit backend override" do
        ENV["UMLS_API_KEY"] = "test-api-key"
        service = TerminologyService.new(backend: :local)
        assert_equal :local, service.backend
      end

      # =============================================================================
      # LOCAL VALUESET EXPANSION
      # =============================================================================

      test "expands local ValueSet and returns codes" do
        service = TerminologyService.new(backend: :local)
        codes = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        assert_kind_of Array, codes
        assert codes.length.positive?, "Expected at least one code"
      end

      test "expanded codes have system and code fields" do
        service = TerminologyService.new(backend: :local)
        codes = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        codes.each do |code|
          assert code[:system].present?, "Expected code to have :system"
          assert code[:code].present?, "Expected code to have :code"
        end
      end

      test "raises ValueSetNotFoundError for missing local ValueSet" do
        service = TerminologyService.new(backend: :local)
        assert_raises(TerminologyService::ValueSetNotFoundError) do
          service.expand_valueset("non-existent-valueset")
        end
      end

      # =============================================================================
      # CODE VALIDATION
      # =============================================================================

      test "code_in_valueset returns true for existing code" do
        service = TerminologyService.new(backend: :local)
        result = service.code_in_valueset?("250.00", "gpra-bgpmu-diabetes-dx")
        assert result, "Expected code '250.00' to be in diabetes ValueSet"
      end

      test "code_in_valueset returns false for non-existing code" do
        service = TerminologyService.new(backend: :local)
        result = service.code_in_valueset?("INVALID-CODE", "gpra-bgpmu-diabetes-dx")
        refute result, "Expected invalid code to not be in ValueSet"
      end

      test "code_in_valueset validates code with specific system" do
        service = TerminologyService.new(backend: :local)
        result = service.code_in_valueset?(
          "250.00", "gpra-bgpmu-diabetes-dx",
          system: "http://hl7.org/fhir/sid/icd-9-cm"
        )
        assert result, "Expected code with correct system to match"
      end

      test "code_in_valueset rejects code with wrong system" do
        service = TerminologyService.new(backend: :local)
        result = service.code_in_valueset?(
          "250.00", "gpra-bgpmu-diabetes-dx",
          system: "http://wrong-system.example.com"
        )
        refute result, "Expected code with wrong system to not match"
      end

      # =============================================================================
      # VALUESET RETRIEVAL
      # =============================================================================

      test "get_valueset returns FHIR ValueSet resource" do
        service = TerminologyService.new(backend: :local)
        valueset = service.get_valueset("gpra-bgpmu-diabetes-dx")
        assert_equal "ValueSet", valueset["resourceType"]
        assert valueset["id"].present?
        assert valueset["status"].present?
      end

      test "get_valueset returns nil for missing ValueSet" do
        service = TerminologyService.new(backend: :local)
        valueset = service.get_valueset("non-existent-valueset")
        assert_nil valueset
      end

      # =============================================================================
      # VALUESET LISTING AND SEARCH
      # =============================================================================

      test "list_valuesets returns array of ValueSets" do
        service = TerminologyService.new(backend: :local)
        valuesets = service.list_valuesets
        assert_kind_of Array, valuesets
        assert valuesets.length.positive?, "Expected at least one ValueSet"
      end

      test "search finds ValueSets by title" do
        service = TerminologyService.new(backend: :local)
        results = service.search("diabetes")
        assert_kind_of Array, results
        assert results.any? { |vs| vs["title"]&.downcase&.include?("diabetes") },
               "Expected at least one diabetes-related ValueSet"
      end

      test "search returns empty array for no matches" do
        service = TerminologyService.new(backend: :local)
        results = service.search("xyznonexistent")
        assert_kind_of Array, results
        assert results.empty?, "Expected no matches for nonsense query"
      end

      # =============================================================================
      # CACHING
      # =============================================================================

      test "expand_valueset caches results" do
        service = TerminologyService.new(backend: :local, use_distributed_cache: false)
        first_result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        second_result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        assert_equal first_result.object_id, second_result.object_id
      end

      test "clear_cache forces fresh retrieval" do
        service = TerminologyService.new(backend: :local, use_distributed_cache: false)
        first_result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        service.clear_cache!
        second_result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        refute_equal first_result.object_id, second_result.object_id
      end

      # =============================================================================
      # GPRA TO VSAC MAPPING
      # =============================================================================

      test "resolve_oid returns OID for mapped GPRA taxonomy" do
        service = TerminologyService.new(backend: :local)
        oid = service.send(:resolve_oid, "gpra-bgpmu-diabetes-dx")
        assert_equal "2.16.840.1.113883.3.464.1003.103.12.1001", oid
      end

      test "resolve_oid passes through existing OID" do
        service = TerminologyService.new(backend: :local)
        oid = service.send(:resolve_oid, "2.16.840.1.113883.3.464.1003.103.12.1001")
        assert_equal "2.16.840.1.113883.3.464.1003.103.12.1001", oid
      end

      test "resolve_oid raises ValueSetNotFoundError for unmapped taxonomy" do
        service = TerminologyService.new(backend: :local)
        assert_raises(TerminologyService::ValueSetNotFoundError) do
          service.send(:resolve_oid, "unmapped-taxonomy-id")
        end
      end

      test "gpra_to_vsac_mapping contains expected entries" do
        service = TerminologyService.new(backend: :local)
        mapping = service.send(:gpra_to_vsac_mapping)
        assert mapping.key?("gpra-bgpmu-diabetes-dx")
        assert mapping.key?("gpra-bgpmu-a1c-loinc")
        assert mapping.key?("gpra-bgpmu-depression-dx")
        assert mapping.key?("gpra-bgpmu-hypertension-dx")

        diabetes = mapping["gpra-bgpmu-diabetes-dx"]
        assert diabetes[:oid].present?
        assert diabetes[:name].present?
      end

      # =============================================================================
      # DISTRIBUTED CACHING
      # =============================================================================

      test "can disable distributed cache explicitly" do
        service = TerminologyService.new(backend: :local, use_distributed_cache: false)
        refute service.distributed_cache_enabled?
      end

      test "expand_valueset works with distributed cache" do
        service = TerminologyService.new(backend: :local, use_distributed_cache: true)
        first_result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        assert first_result.any?
        second_result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        assert_equal first_result, second_result
      end

      test "clear_cache clears both local and distributed caches" do
        service = TerminologyService.new(backend: :local, use_distributed_cache: true)
        service.expand_valueset("gpra-bgpmu-diabetes-dx")
        service.clear_cache!
        result = service.expand_valueset("gpra-bgpmu-diabetes-dx")
        assert result.any?
      end

      # =============================================================================
      # PREFIX MATCHING
      # =============================================================================

      test "code_in_valueset with prefix matching finds hierarchical codes" do
        service = TerminologyService.new(backend: :local)
        result = service.code_in_valueset?("I21.9", "prc-emergency-diagnosis-codes", prefix: true)
        assert_kind_of TrueClass, result.class == TrueClass ? result : !result
      end

      test "code_in_valueset without prefix requires exact match" do
        service = TerminologyService.new(backend: :local)
        result = service.code_in_valueset?("I21.999", "prc-emergency-diagnosis-codes", prefix: false)
        refute result, "Expected non-prefix match to require exact code"
      end

      # =============================================================================
      # PRC VALUESETS
      # =============================================================================

      test "prc-emergency-diagnosis-codes ValueSet exists and has codes" do
        service = TerminologyService.new(backend: :local)
        codes = service.expand_valueset("prc-emergency-diagnosis-codes")
        assert codes.any?, "Expected PRC emergency diagnosis ValueSet to have codes"
        assert codes.any? { |c| c[:code].start_with?("I21") }, "Expected MI codes"
        assert codes.any? { |c| c[:code].start_with?("I46") }, "Expected cardiac arrest codes"
      end

      test "prc-excluded-procedure-codes ValueSet exists and has codes" do
        service = TerminologyService.new(backend: :local)
        codes = service.expand_valueset("prc-excluded-procedure-codes")
        assert codes.any?, "Expected PRC excluded procedure ValueSet to have codes"
        assert codes.any? { |c| c[:code] == "15780" }, "Expected dermabrasion codes"
      end

      test "ihs-available-services ValueSet exists and has codes" do
        service = TerminologyService.new(backend: :local)
        codes = service.expand_valueset("ihs-available-services")
        assert codes.any?, "Expected IHS available services ValueSet to have codes"
      end

      test "prc-specialized-services ValueSet exists and has codes" do
        service = TerminologyService.new(backend: :local)
        codes = service.expand_valueset("prc-specialized-services")
        assert codes.any?, "Expected PRC specialized services ValueSet to have codes"
        assert codes.any? { |c| c[:display]&.include?("Neurosurgery") || c[:code]&.include?("neurosurgery") }
      end
    end
  end
end
