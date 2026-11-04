# frozen_string_literal: true

module Lakeraven
  module EHR
    module Registration
      # What the section edits of a registered patient share (rpms-ux S-REG-20,
      # S-REG-21): the patient's record read through AG, and one rule for who
      # may change it.
      #
      # Editing takes patient.register, the capability that registers: BPRM
      # gates registering and editing a patient on the one policy,
      # CanEditPatients (AGZMENU or AGZMGR), and a view-only user (AGZVIEWONLY)
      # changes nothing (S-REG-20.9).
      class PatientEditsController < WebController
        include RpmsUnavailableRendering

        before_action :require_bprm_registration!
        before_action :require_authentication
        before_action -> { require_capability!("patient.register") }
        before_action :load_record

        private

        def dfn = params[:dfn].to_i

        def load_record
          @record = PatientRecordGateway.find(dfn)
          render "lakeraven/ehr/registration/patients/not_found", status: :not_found unless @record
        end

        def require_bprm_registration!
          return if BackendRegistry.current.provides?(:bprm_registration)

          note_audit_denial("browser access refused: backend lacks bprm_registration")
          render plain: "Registration is not available on this backend.", status: :not_found
        end

        # Files the changes through AG, then shows the record, or the form again
        # with RPMS's reason when it refuses. A block files the changes its own
        # way (the address keeps its history); by default, AG's update.
        def save(form, current, saved_notice)
          changes = form.changes_from(current)
          result = block_given? ? yield(changes) : PatientRecordGateway.update(dfn, changes)
          if result.saved?
            flash[:notice] = saved_notice
            redirect_to registration_patient_path(dfn)
          elsif result.partial?
            # The change is saved and something RPMS keeps beside it is not: say both.
            flash[:alert] = result.message
            redirect_to registration_patient_path(dfn)
          elsif result.outcome_unknown?
            flash.now[:alert] = "RPMS did not say whether the change was saved. Open the patient again to see what is on file before you change it again."
            render_form(:service_unavailable)
          else
            form.errors.add(result.field, :rpms, message: result.message) if result.field && form.respond_to?(result.field)
            flash.now[:alert] = "RPMS did not save the change: #{result.message}"
            render_form(:unprocessable_content)
          end
        end
      end
    end
  end
end
