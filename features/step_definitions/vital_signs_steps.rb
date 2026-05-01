# frozen_string_literal: true

# Vital Signs US Core Compliance Steps — lakeraven-ehr
# ONC § 170.315(g)(10)(i) vital sign observations

Given("a test patient exists with vital signs on file") do
  # Patient DFN 1 and vitals are seeded in test_helper.rb via RpmsRpc.mock!
  # Verify the mock data is reachable.
  patient = Lakeraven::EHR::Patient.find_by_dfn(1)
  assert patient, "Expected patient DFN 1 to exist in mock seeds"
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

Then("vital sign observations should include UCUM unit codes") do
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one observation entry"

  entries.each do |entry|
    obs = entry["resource"]
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
  body = JSON.parse(last_response.body)
  entries = body["entry"] || []
  refute_empty entries, "Expected at least one observation entry"

  entries.each do |entry|
    obs = entry["resource"]
    profiles = obs.dig("meta", "profile") || []
    has_profile = profiles.any? { |p| p.include?("us-core") || p.include?("vitalsigns") }
    assert has_profile,
      "Expected US Core or vitalsigns profile for observation '#{obs.dig('code', 'text')}', got: #{profiles}"
  end
end
