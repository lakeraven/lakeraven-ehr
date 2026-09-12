# frozen_string_literal: true

# Steps for features/behavioral_health/scored_screenings.feature (#474).
#
# Most steps run against ScreeningEntryService directly — the scoring and
# persistence path, with no HTTP and no session, which is also the path the
# tokenized pre-visit link (#471) will use. The two steps that assert the
# safety prompt is *displayed* go through the real form over Rack::Test,
# because "displayed before the form can be submitted" is a claim about the
# rendered page, not about the service.

SCREENING_PHQ9 = Lakeraven::EHR::ScreeningInstrument::PHQ9
SCREENING_GAD7 = Lakeraven::EHR::ScreeningInstrument::GAD7
SCREENING_MOUNT = "/lakeraven-ehr"

module ScreeningStepHelpers
  def instrument_named(name)
    name.to_s.casecmp("gad-7").zero? ? SCREENING_GAD7 : SCREENING_PHQ9
  end

  def ordinal_for(response_text)
    choice = Lakeraven::EHR::ScreeningInstrument::CHOICES.find { |c| c.text == response_text }
    raise ArgumentError, "Unknown response: #{response_text.inspect}" unless choice

    choice.value
  end

  def link_id_at(instrument, position)
    instrument.items.fetch(position - 1).link_id
  end

  # Build an answer set summing to `total`, filling items in order.
  def answers_totalling(instrument, total)
    remaining = total
    instrument.link_ids.index_with do
      take = [ remaining, 3 ].min
      remaining -= take
      take
    end
  end

  def record_screening(instrument, answers, **overrides)
    @screening_instrument = instrument
    @screening_result = Lakeraven::EHR::ScreeningEntryService.new(
      instrument: instrument,
      patient_dfn: @dfn,
      encounter_ien: @visit_ien,
      answers: answers,
      administered_by: "99999",
      **overrides
    ).save
    @screening_answers = answers
    @screening_record = @screening_result.record
  end

  def screening_score
    @screening_result&.score
  end
end
World(ScreeningStepHelpers)

Before("@screenings") { Lakeraven::EHR::ScreeningResponse.delete_all }
After("@screenings") { Lakeraven::EHR::ScreeningResponse.delete_all }

# -- Administration -----------------------------------------------------------

When("the clinician records the following PHQ-9 answers:") do |table|
  answers = table.hashes.each_with_object({}) do |row, acc|
    acc[link_id_at(SCREENING_PHQ9, row["item"].to_i)] = ordinal_for(row["response"])
  end
  record_screening(SCREENING_PHQ9, answers)
end

When("the clinician records every {word} item as {string}") do |name, response|
  instrument = instrument_named(name)
  record_screening(instrument, instrument.link_ids.index_with { ordinal_for(response) })
end

When("the clinician answers PHQ-9 item {int} {string} and every other item {string}") do |position, response, others|
  answers = SCREENING_PHQ9.link_ids.index_with { ordinal_for(others) }
  answers[link_id_at(SCREENING_PHQ9, position)] = ordinal_for(response)
  record_screening(SCREENING_PHQ9, answers)
end

When("the clinician acknowledges the safety prompt and resubmits") do
  record_screening(@screening_instrument, @screening_answers, safety_acknowledged: true)
end

# Pure scoring — no persistence, so the band table can exercise totals (such
# as a maxed PHQ-9) that would otherwise trip the safety gate.
When("the clinician records a {word} totalling {int}") do |name, total|
  instrument = instrument_named(name)
  @screening_instrument = instrument
  @screening_result = nil
  @screening_record = nil
  @standalone_score = instrument.score(answers_totalling(instrument, total))
end

When("the clinician records a {word} totalling {int} on {string}") do |name, total, date|
  instrument = instrument_named(name)
  record_screening(instrument, answers_totalling(instrument, total),
    safety_acknowledged: true, effective_at: Time.zone.parse(date))
end

When("the clinician submits a PHQ-9 with items {int} and {int} unanswered") do |a, b|
  answers = SCREENING_PHQ9.link_ids.index_with { 1 }
  answers.delete(link_id_at(SCREENING_PHQ9, a))
  answers.delete(link_id_at(SCREENING_PHQ9, b))
  record_screening(SCREENING_PHQ9, answers)
end

When("a GAD-7 is completed by the patient before arrival") do
  @screening_instrument = SCREENING_GAD7
  @screening_result = Lakeraven::EHR::ScreeningEntryService.new(
    instrument: SCREENING_GAD7,
    patient_dfn: @dfn,
    answers: SCREENING_GAD7.link_ids.index_with { 1 },
    source: Lakeraven::EHR::ScreeningResponse::SOURCE_PRE_VISIT
  ).save
  @screening_record = @screening_result.record
end

# -- Outcomes -----------------------------------------------------------------

Then("the screening should be recorded") do
  assert @screening_result.success?,
    "Expected the screening to be recorded; got #{@screening_result.error.inspect}"
  refute_nil @screening_record
end

Then("the screening should not be recorded") do
  refute @screening_result.success?, "Expected the screening to be refused"
  assert_equal 0, Lakeraven::EHR::ScreeningResponse.count
end

Then("the total score should be {int}") do |total|
  assert_equal total, @screening_record.total_score
end

Then("the severity band should be {string}") do |band|
  actual = @screening_record&.severity_band || @standalone_score&.band
  assert_equal band, actual
end

Then("no score should be recorded") do
  assert_nil @screening_result.score.total
  assert_equal 0, Lakeraven::EHR::ScreeningResponse.count
end

Then("the missing items should be reported as {int} and {int}") do |a, b|
  expected = [ link_id_at(SCREENING_PHQ9, a), link_id_at(SCREENING_PHQ9, b) ]
  assert_equal expected.sort, @screening_result.missing_link_ids.sort
  assert_equal [ a, b ].sort, @screening_result.score.missing_positions.sort
end

Then("a safety prompt should be required before the screening can be submitted") do
  assert @screening_result.safety_prompt_required?,
    "Expected a safety prompt to be required"
end

Then("no safety prompt should be required") do
  refute @screening_result.safety_prompt_required?
end

Then("the screening should be flagged for safety follow-up") do
  assert @screening_record.safety_flagged?
end

Then("the screening should be attributed to the patient rather than a clinician") do
  assert_equal Lakeraven::EHR::ScreeningResponse::SOURCE_PRE_VISIT, @screening_record.source
  assert_nil @screening_record.administered_by
  assert_equal "Patient/#{@dfn}", @screening_record.to_questionnaire_response.dig(:author, :reference)
end

# -- FHIR ---------------------------------------------------------------------

Then("the score should be retrievable as an Observation with LOINC code {string}") do |code|
  observation = @screening_record.to_observation.to_fhir

  assert_equal "Observation", observation[:resourceType]
  assert_equal code, observation.dig(:code, :coding, 0, :code)
  assert_equal "http://loinc.org", observation.dig(:code, :coding, 0, :system)
  assert_equal @screening_record.total_score.to_f, observation.dig(:valueQuantity, :value)
  refute_nil observation[:effectiveDateTime], "the score must be dated to trend"
end

Then("the answers should be retrievable as a QuestionnaireResponse with {int} items") do |count|
  qr = @screening_record.to_questionnaire_response

  assert_equal "QuestionnaireResponse", qr[:resourceType]
  assert_equal count, qr[:item].length
end

# -- Trending -----------------------------------------------------------------

Then("the patient should have {int} trended {word} scores") do |count, name|
  scores = Lakeraven::EHR::ScreeningResponse.for_patient(@dfn)
    .for_instrument(instrument_named(name).key)
  assert_equal count, scores.count
end

Then("the scores in date order should be {int} and {int}") do |first, second|
  totals = Lakeraven::EHR::ScreeningResponse.for_patient(@dfn).map(&:total_score)
  assert_equal [ first, second ], totals
end

# -- The rendered form (HTTP, no JavaScript) ----------------------------------

Given("the clinician is signed in") do
  post "#{SCREENING_MOUNT}/login", username: "testprovider", password: "test"
  # Being signed in is not access to a named patient: the clinician opens the
  # record explicitly, and that open is audited.
  post "#{SCREENING_MOUNT}/patients/#{@dfn}/context"
end

When("the clinician submits a PHQ-9 with item {int} answered {string}") do |position, response|
  answers = SCREENING_PHQ9.link_ids.index_with { 0 }
  answers[link_id_at(SCREENING_PHQ9, position)] = ordinal_for(response)
  post "#{SCREENING_MOUNT}/patients/#{@dfn}/screenings",
    instrument: SCREENING_PHQ9.key, encounter_ien: @visit_ien.to_s,
    answers: answers.transform_values(&:to_s)
end

Then("the form is redisplayed with a safety prompt") do
  assert_equal 422, last_response.status
  assert_includes last_response.body, "Safety check required"
  assert_includes last_response.body, 'name="safety_acknowledged"'
  refute_includes last_response.body, "<script"
end

Then("no score is recorded") do
  assert_equal 0, Lakeraven::EHR::ScreeningResponse.count
end
