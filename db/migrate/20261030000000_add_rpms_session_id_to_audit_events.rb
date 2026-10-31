# frozen_string_literal: true

# The RPMS session an audited request ran under: the CIA session id sign-on
# returned (CIANBRPC AUTH's reply). RPMS keeps it in ^XTMP("CIA",id) with the
# user, application, workstation and address, so a row here leads to RPMS's
# record of the same session, and back (ADR 0012 rule 12).
class AddRpmsSessionIdToAuditEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :lakeraven_ehr_audit_events, :rpms_session_id, :string
  end
end
