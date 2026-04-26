# frozen_string_literal: true

module Lakeraven
  module EHR
    # HepBWorkflowService -- Hep B maternal-to-infant perinatal case management
    #
    # Wraps ProgramTemplateService with Hep B-specific workflow:
    # HBIG administration, birth dose, vaccine series, and PVST recording.
    #
    # Ported from rpms_redux HepBWorkflowService.
    class HepBWorkflowService
      class << self
        def create_perinatal_case(infant_dfn:, maternal_dfn:, facility:, birth_date:)
          ProgramTemplateService.create_case(
            program_type: "hep_b",
            patient_id: infant_dfn,
            facility: facility,
            anchor_date: birth_date,
            program_data: { "maternal_dfn" => maternal_dfn }
          )
        end

        def record_hbig_administration(kase:, administered_at:, performer_ien:)
          complete_milestone(kase, "hbig_administration", administered_at: administered_at, performer_ien: performer_ien)
        end

        def record_birth_dose(kase:, administered_at:, performer_ien:)
          complete_milestone(kase, "birth_dose", administered_at: administered_at, performer_ien: performer_ien)
        end

        def record_vaccine_dose(kase:, dose_key:, administered_at:, performer_ien:)
          complete_milestone(kase, dose_key, administered_at: administered_at, performer_ien: performer_ien)
        end

        def record_pvst(kase:, hbsag_result:, anti_hbs_result:, tested_at:, performer_ien:)
          kase.set_program_datum(:pvst_hbsag_result, hbsag_result)
          kase.set_program_datum(:pvst_anti_hbs_result, anti_hbs_result)
          kase.set_program_datum(:pvst_tested_at, tested_at.iso8601)
          complete_milestone(kase, "pvst", administered_at: tested_at, performer_ien: performer_ien)
        end

        def case_complete?(kase)
          kase.milestones.where(required: true).incomplete.none?
        end

        def try_close_case(kase)
          return false unless case_complete?(kase)

          kase.advance_to!("closed", closure_reason: "all_required_milestones_complete")
          true
        end

        private

        def complete_milestone(kase, milestone_key, administered_at:, performer_ien:)
          milestone = kase.milestones.find_by!(milestone_key: milestone_key)
          milestone.update!(
            status: :completed,
            completed_at: administered_at,
            notes: "Performed by #{performer_ien} at #{administered_at.iso8601}"
          )
          milestone
        end
      end
    end
  end
end
