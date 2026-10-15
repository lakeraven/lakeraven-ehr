# frozen_string_literal: true

module Lakeraven
  module EHR
    # Establishes a behavioral-health treatment plan and records the two
    # follow-ups the compliance query depends on: a progress review, which
    # moves the next due date, and a supervisor concurrence.
    #
    # The plan is written to the engine database. This service does not call
    # RPMS. Therapy notes and treatment plans stay out of shared RPMS files
    # (lakeraven-ehr#560); file 9002011.56 is not this record.
    #
    # A due date is the anchor date plus the program's configured interval.
    # The interval is an ActiveSupport::Duration from
    # BehavioralHealthProgramConfiguration, so calendar months stay calendar
    # months. This class does not contain an interval of its own.
    #
    # The designated provider cannot concur as supervisor. That refusal is
    # reported on the Result; the concurrence row is not written.
    class TreatmentPlanService
      Result = Struct.new(:success, :record, :error, keyword_init: true) do
        def success? = success
      end

      def initialize(plan: nil, patient_dfn: nil, program_key: nil, date_established: nil,
                     designated_provider_duz: nil, narrative: nil, problems_goals: nil)
        @plan = plan
        @patient_dfn = patient_dfn
        @program_key = program_key
        @date_established = date_established
        @designated_provider_duz = designated_provider_duz
        @narrative = narrative
        @problems_goals = problems_goals
      end

      def create
        established = @date_established.to_date
        Result.new(success: true, record: TreatmentPlan.create!(attributes_for(established)))
      end

      def record_progress_review(reviewed_on:, reviewed_by_duz:)
        reviewed = reviewed_on.to_date
        @plan.transaction do
          @plan.progress_reviews.create!(reviewed_on: reviewed, reviewed_by_duz: reviewed_by_duz.to_s)
          @plan.update!(progress_review_due_on: progress_due_on(reviewed))
        end
        Result.new(success: true, record: @plan)
      end

      def record_concurrence(supervisor_duz:, concurred_at:)
        return failure(:supervisor_is_designated_provider) if @plan.designated_provider?(supervisor_duz)

        @plan.create_concurrence!(supervisor_duz: supervisor_duz.to_s, concurred_at: concurred_at)
        Result.new(success: true, record: @plan)
      end

      private

      def failure(error)
        Result.new(success: false, record: @plan, error: error)
      end

      def attributes_for(established)
        {
          patient_dfn: @patient_dfn,
          program_key: program_key.to_s,
          date_established: established,
          designated_provider_duz: @designated_provider_duz.to_s,
          narrative: @narrative,
          problems_goals: @problems_goals,
          progress_review_due_on: progress_due_on(established),
          end_of_treatment_review_due_on: end_of_treatment_due_on(established)
        }
      end

      def progress_due_on(date)
        date.to_date + program_configuration.progress_review_interval
      end

      def end_of_treatment_due_on(date)
        date.to_date + program_configuration.end_of_treatment_review_interval
      end

      def program_configuration
        @program_configuration ||= BehavioralHealthProgramConfiguration.for_program(program_key)
      end

      def program_key
        @program_key || @plan.program_key
      end
    end
  end
end
