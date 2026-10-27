# frozen_string_literal: true

# Vital Signs US Core Compliance Steps — lakeraven-ehr
# ONC § 170.315(g)(10)(i) vital sign observations

Given("demo patient {string} has vital signs on file") do |dfn|
  # The demo site holds this patient's vitals (features/support/rpms_demo_site.rb).
  refute_empty RpmsRpc::Vital.for_patient(dfn.to_i), "Expected vitals on file for DFN #{dfn}"
end

Then("the first observation should have systolic and diastolic components") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one observation entry"

  observation = entries.first["resource"]
  components = observation["component"] || []
  assert components.length >= 2, "Expected at least 2 components (systolic/diastolic), got #{components.length}"

  codes = components.map { |c| c.dig("code", "coding", 0, "code") }
  assert_includes codes, "8480-6", "Expected systolic component (LOINC 8480-6)"
  assert_includes codes, "8462-4", "Expected diastolic component (LOINC 8462-4)"
end

# US Core 3.1.1 vital-signs profiles apply by LOINC code. RPMS also records
# types with no US Core profile (pain, PA), which the engine keeps under
# vital-signs with the RPMS type as code.text (Observation.vital_from_hash).
# The profile and UCUM checks therefore cover the US Core vitals, and every
# other entry must at least name its RPMS type.
def us_core_vital_entries
  entries = JSON.parse(last_response.body)["entry"] || []
  vitals, others = entries.map { |e| e["resource"] }.partition do |obs|
    (obs.dig("code", "coding") || []).any? { |c| Lakeraven::EHR::Observation::US_CORE_PROFILES.key?(c["code"]) }
  end
  refute_empty vitals, "Expected at least one US Core vital sign observation"
  others.each { |obs| refute_empty obs.dig("code", "text").to_s, "Expected code.text on non-US-Core observation #{obs["id"]}" }
  vitals
end

Then("vital sign observations should include UCUM unit codes") do
  us_core_vital_entries.each do |obs|
    if obs["valueQuantity"]
      system = obs.dig("valueQuantity", "system")
      assert_equal "http://unitsofmeasure.org", system,
        "Expected UCUM system in valueQuantity for #{obs.dig('code', 'text')}"
    elsif obs["component"]
      obs["component"].each do |comp|
        system = comp.dig("valueQuantity", "system")
        assert_equal "http://unitsofmeasure.org", system,
          "Expected UCUM system in component valueQuantity"
      end
    end
  end
end

Then("each observation entry should have category {string}") do |expected_category|
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one observation entry"

  entries.each do |entry|
    categories = entry.dig("resource", "category") || []
    codes = categories.flat_map { |cat| (cat["coding"] || []).map { |c| c["code"] } }
    assert_includes codes, expected_category,
      "Expected category '#{expected_category}' in observation"
  end
end

Then("the first observation should have profile {string}") do |expected_profile|
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one observation entry"

  observation = entries.first["resource"]
  profiles = observation.dig("meta", "profile") || []
  assert_includes profiles, expected_profile,
    "Expected profile '#{expected_profile}', got: #{profiles}"
end

Then("each vital sign observation should reference a US Core profile") do
  us_core_vital_entries.each do |obs|
    profiles = obs.dig("meta", "profile") || []
    has_profile = profiles.any? { |p| p.include?("us-core") || p.include?("vitalsigns") }
    assert has_profile,
      "Expected US Core or vitalsigns profile for observation '#{obs.dig('code', 'text')}', got: #{profiles}"
  end
end

Then("the vital sign observations should have LOINC codes {string}") do |list|
  codes = us_core_vital_entries.flat_map { |obs| (obs.dig("code", "coding") || []).map { |c| c["code"] } }
  assert_equal list.split(/,\s*/).sort, codes.uniq.sort
end
