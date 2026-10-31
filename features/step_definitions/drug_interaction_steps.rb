# frozen_string_literal: true

require "ostruct"

Given("the following patients exist:") do |_table|
  # Patients seeded via test_helper
end

Given("patient {string} has the following active medications:") do |_dfn, table|
  @active_medications = table.hashes.map do |row|
    OpenStruct.new(medication_display: row["drug_name"], medication_code: row["rxnorm_code"])
  end
end

Given("patient {string} has the following allergies:") do |_dfn, table|
  @allergies = table.hashes.map do |row|
    OpenStruct.new(allergen: row["allergen"], allergen_code: row["allergen_code"], category: row["category"])
  end
end

Given("patient {string} has no active medications") do |_dfn|
  @active_medications = []
end

Given("patient {string} has no known allergies") do |_dfn|
  @allergies = []
end

Given("the drug interaction adapter is unavailable") do
  Lakeraven::EHR::DrugInteraction::AdapterFactory.reset_registrations!
  ENV["DRUG_INTERACTION_BACKEND"] = "rpms"
end

Given("the interaction adapter mode is {string}") do |mode|
  Lakeraven::EHR::DrugInteraction::AdapterFactory.reset_registrations!
  ENV["DRUG_INTERACTION_BACKEND"] = mode

  next unless mode == "rpms"

  rpms_local_adapter = Class.new(Lakeraven::EHR::DrugInteraction::LocalAdapter) do
    define_method(:backend) { :rpms }
  end
  Lakeraven::EHR::DrugInteraction::AdapterFactory.register(:rpms) { rpms_local_adapter.new }
end

Given("the RPMS order check returns a critical drug-drug interaction") do
  rpms_adapter = Class.new(Lakeraven::EHR::DrugInteraction::BaseAdapter) do
    define_method(:backend) { :rpms }

    define_method(:check_interactions) do |_meds|
      [
        Lakeraven::EHR::InteractionAlert.new(
          severity: :high,
          drug_a: "warfarin",
          drug_b: "aspirin",
          description: "Synthetic RPMS critical interaction",
          source: "RPMS"
        )
      ]
    end

    define_method(:check_allergies) { |_, _| [] }
  end

  Lakeraven::EHR::DrugInteraction::AdapterFactory.register(:rpms) { rpms_adapter.new }
end

When("I check drug interactions for prescribing {string} with RxNorm {string} to patient {string}") do |name, code, _dfn|
  @allergies ||= []
  service = Lakeraven::EHR::DrugInteractionService.new
  proposed = OpenStruct.new(medication_display: name, medication_code: code)
  @result = service.check(
    active_medications: @active_medications || [],
    proposed_medication: proposed,
    allergies: @allergies
  )
end

When("I batch check the following medications for patient {string}:") do |_dfn, table|
  service = Lakeraven::EHR::DrugInteractionService.new
  @batch_results = {}
  table.hashes.each do |row|
    proposed = OpenStruct.new(medication_display: row["drug_name"], medication_code: row["rxnorm_code"])
    result = service.check(
      active_medications: @active_medications || [],
      proposed_medication: proposed,
      allergies: @allergies || []
    )
    @batch_results[row["drug_name"]] = result
  end
end

Then("the interaction check should be safe") do
  assert @result.safe?, "Expected safe, got interactions: #{@result.interactions.map(&:description)}"
end

Then("the interaction check should not be safe") do
  refute @result.safe?
end

Then("the interaction check should be blocking") do
  assert @result.blocking?
end

Then("the interaction check should not be blocking") do
  refute @result.blocking?
end

Then("the interaction check should be incomplete") do
  assert @result.incomplete?, "Expected incomplete interaction check"
end

Then("I should see a drug-drug interaction between {string} and {string} with severity {string}") do |drug_a, drug_b, severity|
  match = @result.interactions.find do |i|
    names = [ i.drug_a.downcase, i.drug_b.downcase ]
    names.include?(drug_a.downcase) && names.include?(drug_b.downcase) && i.severity.to_s == severity
  end
  assert match, "Expected #{severity} interaction between #{drug_a} and #{drug_b}, got: #{@result.interactions.map { |i| "#{i.drug_a}/#{i.drug_b}(#{i.severity})" }}"
end

Then("there should be no interactions detected") do
  refute @result.incomplete?, "Expected a complete interaction check with no interactions"
  assert_empty @result.interactions
end

Then("the interaction alert list should be empty") do
  assert_empty @result.interactions
end

Then("I should see a drug-allergy interaction for {string}") do |drug|
  match = @result.interactions.find { |i| i.interaction_type == :drug_allergy && i.drug_a.downcase == drug.downcase }
  assert match, "Expected drug-allergy interaction for #{drug}"
end

Then("the interaction description should mention {string}") do |text|
  match = @result.interactions.find { |i| i.description&.downcase&.include?(text.downcase) }
  assert match, "Expected interaction description containing '#{text}'"
end

Then("there should be at least {int} interactions detected") do |count|
  assert_operator @result.interactions.size, :>=, count
end

Then("{string} should have interactions detected") do |drug|
  assert @batch_results[drug].interactions.any?, "Expected interactions for #{drug}"
end

Then("{string} should have no interactions detected") do |drug|
  result = @batch_results[drug]
  refute result.incomplete?, "Expected a complete interaction check with no interactions for #{drug}"
  assert result.interactions.empty?, "Expected no interactions for #{drug}"
end

Then("the result should include FHIR DetectedIssue resources") do
  @detected_issues = @result.to_fhir_detected_issues
  assert @detected_issues.any?
end

Then("each DetectedIssue should have a valid resourceType") do
  @detected_issues.each { |di| assert_equal "DetectedIssue", di[:resourceType] }
end

Then("each DetectedIssue should have a severity") do
  @detected_issues.each { |di| assert di[:severity].present? }
end

Then("each DetectedIssue should have implicated items") do
  @detected_issues.each { |di| assert di[:implicated].length >= 2 }
end

Then("the interaction check should not indicate an error") do
  refute @result.incomplete?, "Expected a complete interaction check"
  assert_nil @result.message
end

Then("the decision source should be {string}") do |source|
  assert_equal source.to_sym, @result.decision_source
end

Then("the interaction check should not be degraded") do
  refute @result.degraded?
end

Then("the interaction source should be {string}") do |source|
  match = @result.interactions.find { |i| i.source.to_s.casecmp?(source) }
  assert match, "Expected an interaction sourced from #{source}, got: #{@result.interactions.map(&:source).inspect}"
end
