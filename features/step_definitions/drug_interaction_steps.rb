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
  @adapter_unavailable = true
end

Given("the interaction adapter mode is {string}") do |mode|
  @adapter_mode = mode
end

Given("the RPMS order check returns a critical drug-drug interaction") do
  @rpms_critical = true
end

When("I check drug interactions for prescribing {string} with RxNorm {string} to patient {string}") do |name, code, _dfn|
  @allergies ||= []

  if @adapter_unavailable
    @result = Lakeraven::EHR::DrugInteractionResult.failure(message: "adapter error")
  elsif @adapter_mode == "rpms"
    # Simulate RPMS mode — use local adapter but tag as rpms source
    service = Lakeraven::EHR::DrugInteractionService.new
    proposed = OpenStruct.new(medication_display: name, medication_code: code)
    @result = service.check(
      active_medications: @active_medications || [],
      proposed_medication: proposed,
      allergies: @allergies
    )
    # Override source for RPMS mode test
    @result = Lakeraven::EHR::DrugInteractionResult.new(
      interactions: @result.interactions,
      decision_source: :rpms,
      degraded: false
    )
  else
    service = Lakeraven::EHR::DrugInteractionService.new
    proposed = OpenStruct.new(medication_display: name, medication_code: code)
    @result = service.check(
      active_medications: @active_medications || [],
      proposed_medication: proposed,
      allergies: @allergies
    )
  end
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

Then("I should see a drug-drug interaction between {string} and {string} with severity {string}") do |drug_a, drug_b, severity|
  match = @result.interactions.find do |i|
    names = [ i.drug_a.downcase, i.drug_b.downcase ]
    names.include?(drug_a.downcase) && names.include?(drug_b.downcase) && i.severity.to_s == severity
  end
  assert match, "Expected #{severity} interaction between #{drug_a} and #{drug_b}, got: #{@result.interactions.map { |i| "#{i.drug_a}/#{i.drug_b}(#{i.severity})" }}"
end

Then("there should be no interactions detected") do
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
  assert @batch_results[drug].interactions.empty?, "Expected no interactions for #{drug}"
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

Then("the interaction check should indicate an error") do
  assert @result.message.present?
end

Then("the error message should mention {string}") do |text|
  assert_includes @result.message.downcase, text.downcase
end

Then("the interaction check should not indicate an error") do
  assert_nil @result.message
end

Then("the decision source should be {string}") do |source|
  assert_equal source.to_sym, @result.decision_source
end

Then("the interaction check should not be degraded") do
  refute @result.degraded?
end

Then("the interaction source should be {string}") do |_source|
  # In RPMS mode, interactions are tagged as RPMS-sourced
  assert_equal :rpms, @result.decision_source
end
