# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Every FHIR search the CapabilityStatement declares serves FHIR resources,
# not the engine's internal records with a resourceType added (#667).
#
# Two checks, over the same demo seeds the US Core samples export uses:
# - no entry, at any depth, carries a snake_case key. FHIR element names are
#   camelCase, so a key like patient_dfn is an internal field leaking out;
# - for the types listed in R4_ELEMENTS, every top-level key is an element
#   FHIR R4 defines for that type.
class FhirSearchEntriesAreFhirTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  ENGINE = "/lakeraven-ehr"

  DOMAIN_RESOURCE = %w[resourceType id meta implicitRules language text contained extension modifierExtension].freeze
  # Top-level elements, FHIR R4 (4.0.1).
  R4_ELEMENTS = {
    "Encounter" => %w[identifier status statusHistory class classHistory type serviceType priority subject
                      episodeOfCare basedOn participant appointment period length reasonCode reasonReference
                      diagnosis account hospitalization location serviceProvider partOf],
    "Procedure" => %w[identifier instantiatesCanonical instantiatesUri basedOn partOf status statusReason category code
                      subject encounter performedDateTime performedPeriod performedString performedAge performedRange
                      recorder asserter performer location reasonCode reasonReference bodySite outcome report
                      complication complicationDetail followUp note focalDevice usedReference usedCode],
    "ServiceRequest" => %w[identifier instantiatesCanonical instantiatesUri basedOn replaces requisition status intent
                           category priority doNotPerform code orderDetail quantityQuantity quantityRatio quantityRange
                           subject encounter occurrenceDateTime occurrencePeriod occurrenceTiming asNeededBoolean
                           asNeededCodeableConcept authoredOn requester performerType performer locationCode
                           locationReference reasonCode reasonReference insurance supportingInfo specimen bodySite note
                           patientInstruction relevantHistory]
  }.transform_values { |names| (DOMAIN_RESOURCE + names).freeze }.freeze

  SNAKE_CASE = /\A[a-z0-9]+(?:_[a-z0-9]+)+\z/

  setup do
    setup_smart_auth(scopes: "system/*.read")
    RpmsRpc.mock! do |m|
      BASELINE_MOCK_SEEDS.call(m)
      LakeravenDemoSeeds.seed(m)
      m.seed_keyed_collection(:referral_search, "1", [
        { ien: "1001", date: Date.new(2026, 1, 15), referral_number: "2026-1001", patient_dfn: 1,
          patient_name: "ANDERSON,ALICE", hrn: "12345", provider: "MARTINEZ,SARAH", facility: "CARDIOLOGY CLINIC",
          status: "A", purpose: "Cardiology consult" }
      ])
    end
  end

  teardown do
    teardown_smart_auth
    RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)
  end

  test "every declared search serves only FHIR elements" do
    leaks = searched_types.flat_map do |type|
      entries(type).flat_map { |resource| problems(type, resource) }
    end

    assert_empty leaks
  end

  test "Encounter, Procedure and ServiceRequest searches serve resources, with content" do
    %w[Encounter Procedure ServiceRequest].each do |type|
      resources = entries(type)
      refute_empty resources, "#{type} search returned no entries from the demo seeds"
      assert(resources.all? { |r| r["resourceType"] == type && r["subject"] }, "#{type} entries: #{resources.inspect}")
    end
  end

  # US Core requires ServiceRequest.code (1..1). An RCIS referral is coded as
  # what it is, a patient referral, with RPMS's purpose as its text.
  test "an RCIS referral is coded as a patient referral, with its purpose as text" do
    referral = entries("ServiceRequest").first

    assert_equal "3457005", referral.dig("code", "coding", 0, "code")
    assert_equal "Cardiology consult", referral.dig("code", "text")
  end

  private

  def searched_types
    get "#{ENGINE}/metadata"
    assert_response :ok
    JSON.parse(response.body).dig("rest", 0, "resource")
        .select { |r| r["interaction"].any? { |i| i["code"] == "search-type" } }
        .map { |r| r["type"] }
  end

  def entries(type)
    get "#{ENGINE}/#{type}", params: search_params(type), headers: @headers
    assert_response :ok, "search #{type}: #{response.body}"
    JSON.parse(response.body).fetch("entry", []).select { |e| e.dig("search", "mode") != "include" }.map { |e| e["resource"] }
  end

  # The same parameters the US Core samples export sends.
  def search_params(type)
    case type
    when "Patient" then { _id: "1" }
    when "Practitioner" then { name: "MARTINEZ" }
    when "AuditEvent" then { patient: "Patient/1" }
    when "Measure", "MeasureReport", "ValueSet" then {}
    else { patient: "1" }
    end
  end

  def problems(type, resource)
    found = snake_case_paths(resource).map { |path| "#{type}: internal field #{path}" }
    allowed = R4_ELEMENTS[type]
    found + (allowed ? (resource.keys - allowed).map { |key| "#{type}: #{key} is not an R4 #{type} element" } : [])
  end

  def snake_case_paths(value, path = "")
    case value
    when Hash
      value.flat_map do |key, child|
        here = path.empty? ? key.to_s : "#{path}.#{key}"
        (key.to_s.match?(SNAKE_CASE) ? [ here ] : []) + snake_case_paths(child, here)
      end
    when Array then value.flat_map { |child| snake_case_paths(child, path) }
    else []
    end
  end
end
