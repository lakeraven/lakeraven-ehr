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
        include RegistrationSiteSettingsLookup

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
          # A save that changes nothing is not an edit: the gateway answers
          # saved without asking RPMS, so there is nothing to audit (#617).
          if changes.present?
            if result.saved? || result.partial?
              record_busa_entry
            elsif result.outcome_unknown?
              record_busa_not_attempted
            end
          end
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

        BUSA_NOT_CONFIRMED = "BUSA entry not confirmed"
        BUSA_NOT_ATTEMPTED = "BUSA entry not attempted"
        BUSA_OUTCOME_UNKNOWN = "the edit's outcome is unknown, so it is not claimed in BUSA"

        # One BUSA security audit entry for an edit RPMS saved (#617), described
        # by the section's busa_description, which holds no PHI. The edit has
        # already happened, so an entry RPMS does not confirm leaves the
        # clerk's flow as it is and is recorded here as a gap. "Not confirmed",
        # never "not filed": the capture from bcer-9.0-20261119-f67498c-ydb
        # files the summary and refuses the patient-detail row; none is captured
        # yet for the pinned build (SecurityAuditGateway).
        def record_busa_entry
          result = SecurityAuditGateway.record_patient_edit(dfn: dfn, description: busa_description)
          return if result.filed?

          record_busa_gap(BUSA_NOT_CONFIRMED, result.reason)
        end

        # An edit whose outcome is unknown may not have happened, so it is not
        # claimed in BUSA; the local row says the entry was not attempted.
        def record_busa_not_attempted
          record_busa_gap(BUSA_NOT_ATTEMPTED, BUSA_OUTCOME_UNKNOWN)
        end

        # The local security row, detached from the request's transaction so a
        # rollback cannot erase it. A row that cannot be written leaves the
        # clerk's response as it is: it is logged (class only, no PHI) and
        # noted on the request's own audit row, which fails closed itself.
        def record_busa_gap(what, reason)
          AuditEvent.create_detached!(
            event_type: "security",
            action: "U",
            outcome: "4",
            outcome_desc: "#{what}: #{reason}",
            entity_type: "Patient",
            entity_identifier: dfn.to_s,
            **AuditContext.agent_attributes,
            agent_network_address: AuditContext.network_address,
            tenant_identifier: AuditContext.tenant_identifier,
            facility_identifier: AuditContext.facility_identifier
          )
        rescue StandardError => e
          Rails.logger.error("[busa] local BUSA audit row could not be written: #{e.class.name}")
          note_audit_anomaly(
            "#{what} for Patient #{dfn}; the local audit row recording it could not be written (#{e.class.name})"
          )
        end
      end
    end
  end
end
