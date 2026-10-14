# frozen_string_literal: true

# Steps for features/behavioral_health/treatment_plans.feature (#475).
#
# These run against the model and the worklist query directly: the claims are
# about what is STORED and what the "reviews overdue" preset counts, not about
# a rendered page. The worklist surface itself belongs to #470.

TREATMENT_PLAN_THERAPIST = "99999"

module TreatmentPlanStepHelpers
  def establish_plan(patient_dfn: @dfn, on:, provider: TREATMENT_PLAN_THERAPIST)
    Lakeraven::EHR::TreatmentPlan.establish!(
      patient_dfn: patient_dfn,
      established_on: Date.iso8601(on),
      designated_provider: provider
    )
  end

  def overdue_preset
    Lakeraven::EHR::TreatmentPlanWorklist.new(as_of: @worklist_date).preset("reviews-overdue")
  end
end
World(TreatmentPlanStepHelpers)

Before("@treatment_plans") do
  Lakeraven::EHR::TreatmentPlanReview.delete_all
  Lakeraven::EHR::TreatmentPlan.delete_all
end
After("@treatment_plans") do
  Lakeraven::EHR::TreatmentPlanReview.delete_all
  Lakeraven::EHR::TreatmentPlan.delete_all
end

Given("patient {int} has an active behavioral-health episode") do |dfn|
  @dfn = dfn
end

# -- Establishing -------------------------------------------------------------

When("the therapist establishes a treatment plan on {string}") do |date|
  @plan = establish_plan(on: date)
end

Given("a treatment plan established on {string} with no progress review") do |date|
  @plan = establish_plan(on: date)
end

Given("a treatment plan for patient {int} established on {string} with no progress review") do |dfn, date|
  establish_plan(patient_dfn: dfn, on: date)
end

Then("a 60-day progress-review due date of {string} is stored on the plan") do |date|
  stored = Lakeraven::EHR::TreatmentPlan.find(@plan.id)
  assert_equal Date.iso8601(date), stored.progress_review_due_on
end

Then("an end-of-treatment review due date of {string} can be recorded") do |date|
  @plan.update!(end_of_treatment_review_due_on: Date.iso8601(date))
  assert_equal Date.iso8601(date), Lakeraven::EHR::TreatmentPlan.find(@plan.id).end_of_treatment_review_due_on
end

When("a treatment plan is established with no designated provider") do
  @plan = nil
  @plan_error = nil
  begin
    @plan = establish_plan(on: "2026-12-01", provider: nil)
  rescue ActiveRecord::RecordInvalid => e
    @plan_error = e
  end
end

Then("the plan is not stored") do
  assert_nil @plan
  assert_equal 0, Lakeraven::EHR::TreatmentPlan.where(patient_dfn: @dfn).count
end

Then("the error names the designated provider") do
  refute_nil @plan_error
  assert @plan_error.record.errors.key?(:designated_provider),
         "expected an error on designated_provider, got #{@plan_error.record.errors.full_messages.inspect}"
end

Given("the plan ended on {string}") do |date|
  @plan.end!(on: Date.iso8601(date))
end

# -- Worklist -----------------------------------------------------------------

When("the worklist is viewed on {string}") do |date|
  @worklist_date = Date.iso8601(date)
end

Then("the {string} preset shows a count of {int}") do |label, count|
  preset = overdue_preset
  assert_equal label, preset.label.downcase
  assert_equal count, preset.count
end

Then("the {string} preset lists the plan for patient {int}") do |label, dfn|
  preset = overdue_preset
  assert_equal label, preset.label.downcase
  assert_equal [ dfn ], preset.plans.map(&:patient_dfn)
end

# -- Supervisor concurrence ---------------------------------------------------

When("supervising clinician {string} concurs with the plan at {string}") do |duz, at|
  @plan.concur!(supervisor: duz, at: Time.iso8601(at))
end

Then("the plan records the concurrence by {string} at {string}") do |duz, at|
  stored = Lakeraven::EHR::TreatmentPlan.find(@plan.id)
  assert_equal duz, stored.concurring_supervisor
  assert_equal Time.iso8601(at), stored.supervisor_concurred_at
end

When("the designated provider concurs with the plan") do
  @concurrence_error = nil
  begin
    @plan.concur!(supervisor: @plan.designated_provider, at: Time.utc(2026, 12, 2, 9, 30))
  rescue ActiveRecord::RecordInvalid => e
    @concurrence_error = e
  end
end

Then("the concurrence is refused") do
  refute_nil @concurrence_error
  stored = Lakeraven::EHR::TreatmentPlan.find(@plan.id)
  assert_nil stored.concurring_supervisor
  assert_nil stored.supervisor_concurred_at
end

# -- Progress review ----------------------------------------------------------

When("the therapist documents the 60-day progress review on {string}") do |date|
  @plan.record_progress_review!(reviewed_on: Date.iso8601(date), reviewed_by: TREATMENT_PLAN_THERAPIST)
end

Then("the next review due date is {string}") do |date|
  assert_equal Date.iso8601(date), Lakeraven::EHR::TreatmentPlan.find(@plan.id).progress_review_due_on
end

Then("the plan keeps a record of the review on {string}") do |date|
  reviews = Lakeraven::EHR::TreatmentPlan.find(@plan.id).reviews
  assert_equal [ Date.iso8601(date) ], reviews.map(&:reviewed_on)
  assert_equal [ TREATMENT_PLAN_THERAPIST ], reviews.map(&:reviewed_by)
end
