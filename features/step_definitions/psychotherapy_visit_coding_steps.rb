# frozen_string_literal: true

# Steps for features/behavioral_health/psychotherapy_visit_coding.feature (#476).

Given("the documenting provider has DUZ {int}") do |duz|
  @documented_by_duz = duz.to_s
end

When("I ask for the default psychotherapy CPT code for a new behavioral-health episode") do
  @default_psychotherapy_cpt = Lakeraven::EHR::PsychotherapyVisitCodingRules.default_cpt_code_for_new_episode
end

Then("the offered psychotherapy CPT code should be {string}") do |code|
  assert_equal code, @default_psychotherapy_cpt
end

When("I document psychotherapy visit coding for encounter kind {string} with duration {int} minutes") do |kind, minutes|
  document_psychotherapy_coding(encounter_kind: kind, duration_minutes: minutes)
end

When("I document psychotherapy visit coding for encounter kind {string} with duration minutes absent") do |kind|
  document_psychotherapy_coding(encounter_kind: kind, duration_minutes: nil)
end

When("I document psychotherapy visit coding for encounter kind {string} with duration {int} minutes and selected CPT code {string}") do |kind, minutes, code|
  document_psychotherapy_coding(encounter_kind: kind, duration_minutes: minutes, selected_cpt_code: code)
end

When("I document psychotherapy visit coding for encounter kind {string} with duration minutes absent and selected CPT code {string}") do |kind, code|
  document_psychotherapy_coding(encounter_kind: kind, duration_minutes: nil, selected_cpt_code: code)
end

Given("psychotherapy visit coding for encounter kind {string} with duration {int} minutes is on file") do |kind, minutes|
  document_psychotherapy_coding(encounter_kind: kind, duration_minutes: minutes, persist: true)
end

Then("the psychotherapy visit coding should be resolved") do
  assert @visit_coding_record.resolved?, "expected resolved coding, blocking=#{ @visit_coding_record.blocking_reason.inspect }"
end

Then("the psychotherapy visit coding should not be resolved") do
  refute @visit_coding_record.resolved?
end

Then("the psychotherapy CPT code should be {string}") do |code|
  assert_equal code, @visit_coding_record.cpt_code
end

Then("the psychotherapy visit coding blocking reason should be {string}") do |reason|
  assert_equal reason.to_sym, @visit_coding_record.blocking_reason
end

Then("there should be no psychotherapy CPT code proposed") do
  assert_nil @visit_coding_record.cpt_code
end

Then("the claim procedure handoff should include procedure code {string} and duration minutes absent") do |code|
  handoff = @visit_coding_record.to_claim_procedure_handoff
  assert_equal code, handoff[:procedure_code]
  assert_nil handoff[:duration_minutes]
end

Then("the claim procedure handoff should include procedure code {string} and duration minutes {int}") do |code, minutes|
  handoff = @visit_coding_record.to_claim_procedure_handoff
  assert_equal code, handoff[:procedure_code]
  assert_equal minutes, handoff[:duration_minutes]
end

Then("the psychotherapy visit coding should be refused with blocking reason {string}") do |reason|
  refute @visit_coding_record.valid?
  assert_equal reason.to_sym, @visit_coding_record.blocking_reason
end

When("the provider attempts to finalize the behavioral-health visit") do
  @encounter = Lakeraven::EHR::Encounter.new(
    status: "in-progress", class_code: "AMB", patient_dfn: @dfn, ien: @visit_ien
  )
  @finalization_result = Lakeraven::EHR::BehavioralHealthVisitFinalizationService.new(
    encounter: @encounter,
    visit_coding: @visit_coding_record
  ).finalize
end

Then("the visit finalization should fail with error {string}") do |error|
  refute @finalization_result.success?
  assert_equal error.to_sym, @finalization_result.error
end

Then("the visit finalization should succeed") do
  assert @finalization_result.success?, "expected success, got #{@finalization_result.error.inspect}"
end

Then("the encounter should remain in progress") do
  assert_equal "in-progress", @encounter.status
end

Then("the encounter should be finished") do
  assert_equal "finished", @encounter.status
end

def document_psychotherapy_coding(encounter_kind:, duration_minutes:, selected_cpt_code: nil, persist: false)
  kind = normalize_encounter_kind(encounter_kind)
  attrs = {
    patient_dfn: @dfn,
    encounter_ien: @visit_ien.to_s,
    encounter_kind: kind,
    duration_minutes: duration_minutes,
    documented_by_duz: @documented_by_duz
  }
  attrs[:selected_cpt_code] = selected_cpt_code if selected_cpt_code

  if persist
    @visit_coding_record = Lakeraven::EHR::BehavioralHealthVisitCoding.create!(attrs)
    return
  end

  @visit_coding_record = Lakeraven::EHR::BehavioralHealthVisitCoding.new(attrs)
  @visit_coding_record.validate
end

def normalize_encounter_kind(label)
  case label
  when "psychiatric_diagnostic_evaluation"
    Lakeraven::EHR::PsychotherapyVisitCodingRules::ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION
  when "individual_psychotherapy"
    Lakeraven::EHR::PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY
  else
    raise ArgumentError, "unknown encounter kind #{label.inspect}"
  end
end
