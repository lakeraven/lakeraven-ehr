# frozen_string_literal: true

# Steps for features/behavioral_health/treatment_plan_review_dates.feature (#475).

module TreatmentPlanStepHelpers
  include ActiveSupport::Testing::TimeHelpers

  def parse_interval(value)
    case value.strip
    when /^(\d+)\s+days?$/i then Regexp.last_match(1).to_i.days
    when /^(\d+)\s+months?$/i then Regexp.last_match(1).to_i.months
    else
      raise ArgumentError, "Unsupported interval: #{value.inspect}"
    end
  end

  def program_configuration
    Lakeraven::EHR::BehavioralHealthProgramConfiguration
  end

  def treatment_plan_service(**attrs)
    Lakeraven::EHR::TreatmentPlanService.new(**attrs)
  end

  def establish_plan(patient_dfn:, program_key:, established_on:, provider_duz:)
    @patient_dfn = patient_dfn.to_i
    @program_key = program_key
    @treatment_plan_result = treatment_plan_service(
      patient_dfn: @patient_dfn,
      program_key: program_key,
      date_established: Date.parse(established_on),
      designated_provider_duz: provider_duz,
      narrative: "Synthetic treatment plan narrative.",
      problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
    ).create
    assert @treatment_plan_result.success?, @treatment_plan_result.error.inspect
    @treatment_plan = @treatment_plan_result.record
    @plan_service = treatment_plan_service(plan: @treatment_plan)
  end
end
World(TreatmentPlanStepHelpers)

Before("@treatment_plans") do
  Lakeraven::EHR::BehavioralHealthProgramConfiguration.reset!
  if defined?(Lakeraven::EHR::TreatmentPlanProgressReview)
    Lakeraven::EHR::TreatmentPlanProgressReview.delete_all
  end
  if defined?(Lakeraven::EHR::TreatmentPlanConcurrence)
    Lakeraven::EHR::TreatmentPlanConcurrence.delete_all
  end
  if defined?(Lakeraven::EHR::TreatmentPlan)
    Lakeraven::EHR::TreatmentPlan.delete_all
  end
end

Given("the behavioral health program {string} has review intervals:") do |program_key, table|
  intervals = {}
  table.hashes.each do |row|
    intervals[row["interval"].to_sym] = parse_interval(row["value"])
  end
  program_configuration.assign(
    program_key: program_key,
    progress_review_interval: intervals.fetch(:progress_review),
    end_of_treatment_review_interval: intervals.fetch(:end_of_treatment_review)
  )
end

When("a treatment plan for patient {string} in program {string} is established on {string} by provider {string}") do |dfn, program, date, provider|
  establish_plan(patient_dfn: dfn, program_key: program, established_on: date, provider_duz: provider)
end

Given("a treatment plan for patient {string} in program {string} was established on {string} by provider {string}") do |dfn, program, date, provider|
  establish_plan(patient_dfn: dfn, program_key: program, established_on: date, provider_duz: provider)
end

When("a progress review for the plan is completed on {string} by provider {string}") do |date, provider|
  result = @plan_service.record_progress_review(
    reviewed_on: Date.parse(date),
    reviewed_by_duz: provider
  )
  assert result.success?, result.error.inspect
end

Given("a progress review for the plan was completed on {string} by provider {string}") do |date, provider|
  result = @plan_service.record_progress_review(
    reviewed_on: Date.parse(date),
    reviewed_by_duz: provider
  )
  assert result.success?, result.error.inspect
end

When("the date is {string}") do |date|
  travel_to Time.zone.parse(date).middle_of_day
  @as_of = Date.parse(date)
end

Then("the plan's next progress-review due date should be {string}") do |expected|
  assert_equal Date.parse(expected), @treatment_plan.progress_review_due_on
end

Then("the plan's end-of-treatment review due date should be {string}") do |expected|
  assert_equal Date.parse(expected), @treatment_plan.end_of_treatment_review_due_on
end

Then("the plan should have {int} recorded progress review on {string}") do |count, date|
  reviews = @treatment_plan.progress_reviews.order(:reviewed_on)
  assert_equal count, reviews.count
  assert_equal Date.parse(date), reviews.last.reviewed_on
end

Then("the plan should not be progress-review overdue") do
  as_of = @as_of || Date.current
  refute @treatment_plan.progress_review_overdue?(as_of: as_of),
         "expected plan #{@treatment_plan.id} not overdue as of #{as_of}"
end

Then("the plan should be progress-review overdue") do
  as_of = @as_of || Date.current
  assert @treatment_plan.progress_review_overdue?(as_of: as_of),
         "expected plan #{@treatment_plan.id} overdue as of #{as_of}"
end

When("supervisor {string} concurs with the plan on {string}") do |supervisor_duz, timestamp|
  @concurrence_result = @plan_service.record_concurrence(
    supervisor_duz: supervisor_duz,
    concurred_at: Time.zone.parse(timestamp)
  )
end

When("supervisor {string} attempts to concur with the plan on {string}") do |supervisor_duz, timestamp|
  @concurrence_result = @plan_service.record_concurrence(
    supervisor_duz: supervisor_duz,
    concurred_at: Time.zone.parse(timestamp)
  )
end

Then("the plan's concurrence should be by supervisor {string} on {string}") do |supervisor_duz, date|
  concurrence = @treatment_plan.concurrence
  assert concurrence, "expected a concurrence record"
  assert_equal supervisor_duz, concurrence.supervisor_duz
  assert_equal Time.zone.parse(date), concurrence.concurred_at
end

Then("the concurrence should be refused") do
  refute @concurrence_result.success?, "expected concurrence refusal"
  assert_equal :supervisor_is_designated_provider, @concurrence_result.error
end

Then("the progress-review overdue count should be {int}") do |expected|
  as_of = @as_of || Date.current
  assert_equal expected, Lakeraven::EHR::TreatmentPlan.progress_review_overdue_count(as_of: as_of)
end
