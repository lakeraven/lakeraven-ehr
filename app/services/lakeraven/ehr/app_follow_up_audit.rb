# frozen_string_literal: true

module Lakeraven
  module EHR
    # One AuditEvent per step of an outside app's follow-up (#988, #989):
    # posted (C), confirmed or rejected (U), and written to RPMS (E). The row
    # names the app, the patient and the referral by identifier only (ADR
    # 0002): never the summary, which is free text.
    module AppFollowUpAudit
      module_function

      def record!(follow_up, action:, what:, outcome: "0", duz: nil)
        AuditEvent.create!(
          event_type: "application", action: action, outcome: outcome,
          agent_who_type: duz ? "Practitioner" : "Device",
          agent_who_identifier: duz || follow_up.client_id,
          agent_name: duz ? follow_up.reviewed_by_name : follow_up.app_name,
          entity_type: "Patient", entity_identifier: follow_up.patient_dfn.to_s,
          outcome_desc: "outside-app follow-up #{follow_up.id} (Device/#{follow_up.client_id}) " \
                        "about RPMS referral #{follow_up.referral_ien}: #{what}"
        )
      end
    end
  end
end
