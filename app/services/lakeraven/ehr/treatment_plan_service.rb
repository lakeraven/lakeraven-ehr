# frozen_string_literal: true

module Lakeraven
  module EHR
    # Establishes a behavioral-health treatment plan and records the two
    # follow-ups the compliance query depends on: a progress review, which
    # moves the next due date from the latest review, and a supervisor
    # concurrence.
    #
    # The plan is written to the engine database. This service does not call
    # RPMS. Therapy notes and treatment plans stay out of shared RPMS files
    # (lakeraven-ehr#560); file 9002011.56 is not this record.
    #
    # A due date is the anchor date plus the program's configured interval.
    # The interval is an ActiveSupport::Duration from
    # BehavioralHealthProgramConfiguration, so calendar months stay calendar
    # months. This class does not contain an interval of its own. A review
    # dated before the latest one is stored and does not pull the due date
    # backward. The plan row is locked across that write so the due date is
    # taken from the latest review on file. A review dated in the future
    # is refused.
    #
    # The designated provider cannot concur as supervisor. That refusal is
    # reported on the Result; the concurrence row is not written. A plan has
    # one concurrence; a second call is refused so the first is not replaced.
    # A blank supervisor or a missing time is an invalid concurrence. Losing
    # the race on the unique index is the same refusal, and the first row stays.
    #
    # A review dated before the plan was established is refused. A plan cannot
    # be established after today. Invalid input, an unknown program, and a
    # stored interval that cannot be read are failed Results.
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
        established = coerce_date(@date_established)
        error = create_error(established)
        return failure(error) if error

        Result.new(success: true, record: TreatmentPlan.create!(attributes_for(established)))
      rescue BehavioralHealthProgramConfiguration::UnknownProgram
        failure(:unknown_program)
      rescue ActiveRecord::RecordInvalid
        failure(:invalid_plan)
      rescue ArgumentError
        failure(:invalid_program_configuration)
      end

      def record_progress_review(reviewed_on:, reviewed_by_duz:)
        reviewed = coerce_date(reviewed_on)
        error = progress_review_error(reviewed, reviewed_by_duz)
        return failure(error) if error
        return failure(:invalid_program_configuration) unless readable_intervals?(progress: true)

        write_progress_review(reviewed, reviewed_by_duz)
        Result.new(success: true, record: @plan)
      rescue BehavioralHealthProgramConfiguration::UnknownProgram
        failure(:unknown_program)
      rescue ActiveRecord::RecordInvalid
        failure(:invalid_review)
      rescue ArgumentError
        failure(:invalid_program_configuration)
      end

      def record_concurrence(supervisor_duz:, concurred_at:)
        error = concurrence_error(supervisor_duz, concurred_at)
        return failure(error) if error

        write_concurrence(supervisor_duz, concurred_at)
        Result.new(success: true, record: @plan)
      rescue ActiveRecord::RecordInvalid
        failure(:invalid_concurrence)
      rescue ActiveRecord::RecordNotUnique
        failure(:already_concurred)
      end

      private

      def failure(error)
        Result.new(success: false, record: @plan, error: error)
      end

      # DateTime is a Date, so is_a?(Date) would keep the clock time. Noon today
      # then compares after midnight and is refused as a future review. A plain
      # Date stays as it is; anything else that can become a date is reduced
      # with to_date before it is compared or written.
      def coerce_date(value)
        return if value.nil?
        return value if value.instance_of?(Date)
        return unless value.respond_to?(:to_date)

        value.to_date
      rescue ArgumentError
        nil
      end

      def create_error(established)
        return :invalid_plan unless established
        return :invalid_plan if established.to_date > Date.current
        return :invalid_program_configuration unless readable_intervals?(
          progress: true,
          end_of_treatment: true
        )

        nil
      end

      def progress_review_error(reviewed, reviewed_by_duz)
        return :invalid_review unless reviewed && reviewed_by_duz.present?
        return :reviewed_on_in_future if reviewed > Date.current
        return :reviewed_before_established if @plan.date_established && reviewed.to_date < @plan.date_established

        nil
      end

      def concurrence_error(supervisor_duz, concurred_at)
        return :invalid_concurrence if supervisor_duz.blank? || concurred_at.blank?
        return :supervisor_is_designated_provider if @plan.designated_provider?(supervisor_duz)
        return :already_concurred if concurrence_recorded?

        nil
      end

      # SAVEPOINT so a unique-index loss does not abort the caller's transaction.
      # The failed insert rolls back; the first concurrence stays readable.
      def write_concurrence(supervisor_duz, concurred_at)
        @plan.transaction(requires_new: true) do
          @plan.create_concurrence!(supervisor_duz: supervisor_duz.to_s, concurred_at: concurred_at)
        end
      end

      # Lock the plan row until the due date is written. A concurrent review
      # then sees this row when it reads the latest reviewed_on, or this call
      # sees theirs.
      def write_progress_review(reviewed, reviewed_by_duz)
        @plan.transaction do
          @plan.lock!
          @plan.progress_reviews.create!(reviewed_on: reviewed, reviewed_by_duz: reviewed_by_duz.to_s)
          @plan.update!(progress_review_due_on: progress_due_on(latest_reviewed_on(reviewed)))
        end
      end

      # The row just inserted is included even if the aggregate has not
      # caught up inside this transaction. An earlier date does not win.
      def latest_reviewed_on(reviewed)
        [ @plan.progress_reviews.maximum(:reviewed_on), reviewed ].compact.max
      end

      def concurrence_recorded?
        TreatmentPlanConcurrence.exists?(treatment_plan_id: @plan.id)
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

      # A stored part count that is not a positive integer raises ArgumentError
      # when the duration is read. That is a failed Result, not an exception.
      def readable_intervals?(progress: false, end_of_treatment: false)
        config = program_configuration
        config.progress_review_interval if progress
        config.end_of_treatment_review_interval if end_of_treatment
        true
      rescue ArgumentError
        false
      end

      # Create has no plan. A nil key reaches for_program and fails as an
      # unknown program.
      def program_key
        @program_key || @plan&.program_key
      end
    end
  end
end
