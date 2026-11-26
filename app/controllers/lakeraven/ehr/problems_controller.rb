# frozen_string_literal: true

module Lakeraven
  module EHR
    # A provider adds the diagnosis Find a diagnosis showed to the patient's
    # problem list, and as the purpose of visit on one of today's open visits
    # when it is why the patient came (rpms-ux S-VIS-02.2, S-VIS-02.3).
    #
    # new is the confirmation: the concept as RPMS's terminology holds it, a
    # problem already on the list for it, today's open visits and the
    # "Today's purpose of visit" box, the status and, for a concept that asks
    # for one, the side. create reads the concept, the list and the visits
    # again from RPMS, so nothing posted is taken on trust, and files through
    # ProblemEntryGateway. show reads what RPMS stored back: the problem from
    # the patient's list and the visit's diagnoses filed against it.
    class ProblemsController < WebController
      include VisitCharting

      rate_limit only: %i[show]

      helper_method :status_choice, :laterality_choices, :today_visits

      def new
        load_concept or return
        refuse_substance_use or return
        load_form_state
        @on_file = ProblemEntryGateway.check(@dfn, @concept[:concept_id])[:on_file]
      rescue *UNKNOWN_OUTCOME_ERRORS => e
        rpms_did_not_answer(e)
      end

      def create
        load_concept or return
        refuse_substance_use or return
        load_form_state
        return refuse(@input_refusal) if (@input_refusal = input_refusal)

        result = ProblemEntryGateway.add(@dfn, concept_id: @concept[:concept_id], status: @status,
                                               laterality: @laterality, visit_ien: (canonical_ien(@visit_ien) if @pov),
                                               provider_duz: current_duz)
        respond_to_result(result)
      rescue *UNKNOWN_OUTCOME_ERRORS => e
        rpms_did_not_answer(e)
      end

      def show
        @problem = ProblemEntryGateway.problem(@dfn, params[:id])
        return render_not_found unless @problem && ProblemEntryGateway.shareable?(ProblemEntryGateway.problem_codes(@problem))

        @visit_ien = canonical_ien(params[:visit_ien])
        @visit = @visit_ien && Array(EncounterGateway.visits(@dfn)).find { |row| canonical_ien(row[:visit_ien]) == @visit_ien }
        @diagnoses = @visit ? ProblemEntryGateway.diagnoses(@visit_ien, @problem[:ien]) : []
      rescue *UNKNOWN_OUTCOME_ERRORS => e
        rpms_did_not_answer(e)
      end

      private

      def charted_thing = "problem"

      def load_concept
        @dts_id = params[:dts_id].to_s
        @concept = @dts_id.match?(/\A[1-9]\d*\z/) ? TerminologyGateway.concept(@dts_id) : nil
        return true if @concept

        @refusal = "RPMS's terminology holds no such concept. Find the diagnosis again."
        render :missing, status: :not_found
        false
      end

      # The shared problem list takes no substance use diagnosis (ConditionGateway),
      # and these pages show none: a concept BSTS maps into ICD-10-CM F10-F19,
      # or to a code that cannot be classified, is refused before RPMS is asked
      # about the patient's list.
      def refuse_substance_use
        return true if ProblemEntryGateway.shareable?(@concept[:icd])

        @refusal = "A diagnosis in ICD-10-CM F10-F19, or one that cannot be classified, is not added to the shared problem list. Nothing was saved."
        render :missing, status: :unprocessable_entity
        false
      end

      def load_form_state
        @status = params[:status].is_a?(String) ? params[:status] : status_choice
        @laterality = params[:laterality].is_a?(String) ? params[:laterality].presence : nil
        @pov = params.key?(:pov) ? params[:pov] == "1" : nil
        @visit_ien = params[:visit_ien].is_a?(String) ? params[:visit_ien] : nil
        @open_visits = today_visits
      end

      def input_refusal
        return "This concept cannot be chosen as a diagnosis." unless @concept[:selectable]
        return "Choose one of the problem list's statuses." unless ProblemEntryGateway::STATUSES.include?(@status)
        return "Choose the side: #{laterality_choices.join(', ')}." if @concept[:prompt_laterality] && !laterality_choices.include?(@laterality)
        return "This concept does not ask for a side." if !@concept[:prompt_laterality] && @laterality
        return unless @pov

        return "The patient's visits could not be read, so it cannot be filed as the visit's purpose now. Nothing was saved." if @open_visits.nil?
        return "The patient has no open visit today, so it cannot be today's purpose of visit. Nothing was saved." if @open_visits.empty?

        "Choose one of today's open visits." unless today_visit?(@visit_ien)
      end

      def respond_to_result(result)
        @result = result
        case result.outcome
        when :filed, :problem_only, :pov_unknown
          @write_outcome = :written
          redirect_to patient_problem_path(@dfn, result.problem[:ien], visit_ien: (canonical_ien(@visit_ien) if @pov)),
                      notice: written_notice(result), alert: partial_alert(result)
        when :duplicate
          @write_outcome = :nothing_written
          @on_file = result.on_file
          refuse("This concept is on the patient's problem list already. Nothing was saved.", status: :conflict)
        when :forbidden
          @write_outcome = :nothing_written
          refuse("RPMS refused this request: #{result.reason} Nothing was saved.", status: :forbidden)
        when :refused
          @write_outcome = :nothing_written
          refuse([ "RPMS did not add the problem.", result.reason, "Nothing was saved." ].compact.join(" "))
        else
          @write_outcome = :unknown
          refuse([ result.reason, "The outcome is unknown. Check the patient's problem list before adding it again." ].compact.join(" "))
        end
      end

      def written_notice(result)
        return "Added to the problem list." unless result.filed? && result.diagnoses.any?

        "Added to the problem list and as today's purpose of visit."
      end

      def partial_alert(result)
        case result.outcome
        when :problem_only
          [ "RPMS did not file it as the visit's purpose.", result.reason ].compact.join(" ")
        when :pov_unknown
          "Whether RPMS filed it as the visit's purpose is unknown. Check the visit before adding it again."
        end
      end

      def refuse(message, status: :unprocessable_entity)
        @refusal = message
        render :new, status: status
      end

      def rpms_did_not_answer(error)
        Rails.logger.error("[problems] #{action_name} raised #{error.class}")
        if error.is_a?(::RpmsRpc::Client::RpcRefusedError)
          @refusal = "RPMS refused this request: #{RpcSupport.sanitize(error.message)} Nothing was saved."
          status = :forbidden
        else
          @refusal = "RPMS did not answer, so nothing was saved. Try again shortly."
          status = :service_unavailable
        end
        @concept ? render(:new, status: status) : render(:missing, status: status)
      end

      def render_not_found
        @refusal = "This problem is not on the patient's problem list, or is not shown here."
        render :missing, status: :not_found
      end

      # The concept's default status on the problem list, else what RPMS files
      # when none is sent.
      def status_choice
        default = @concept && @concept[:default_status]
        ProblemEntryGateway::STATUSES.include?(default) ? default : ProblemEntryGateway::DEFAULT_STATUS
      end

      def laterality_choices = ProblemEntryGateway::LATERALITIES

      # The patient's open visits dated today on the site's clock, or nil
      # when the visits could not be read.
      def today_visits
        @today_visits ||= begin
          rows = read_open_visits(@dfn)
          rows&.select { |row| row[:datetime].respond_to?(:to_date) && row[:datetime].to_date == SiteTime.today }
        end
      end

      def today_visit?(posted)
        ien = canonical_ien(posted)
        ien && Array(today_visits).any? { |row| canonical_ien(row[:visit_ien]) == ien }
      end
    end
  end
end
