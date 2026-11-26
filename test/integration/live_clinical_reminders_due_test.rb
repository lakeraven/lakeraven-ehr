# frozen_string_literal: true

require "test_helper"

# Live (#986): the reminders RPMS flags due for a patient become the CDS
# service's preventive-care alerts. ORQQPX REMINDERS LIST, read through
# RpmsRpc::HealthSummary.clinical_reminders, answers DUE FLAG 1 for a due
# reminder; the service read a :status key the gem no longer sends, so no
# reminder was ever due. It only reads, so LIVE_RPMS=1 alone runs it, signed
# on as the provider persona:
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_clinical_reminders_due_test.rb
class LiveClinicalRemindersDueTest < ActiveSupport::TestCase
  DEMO_PATIENT_ONE = 4

  setup do
    skip "live: set LIVE_RPMS=1 against an RPMS container" unless defined?(LIVE_RPMS) && LIVE_RPMS
  end

  test "a reminder RPMS flags due is evaluated as due" do
    due = RpmsRpc::HealthSummary.clinical_reminders(DEMO_PATIENT_ONE).select { |r| r[:due_flag] == 1 }
    refute_empty due, "the pinned build flags no reminder due for DFN #{DEMO_PATIENT_ONE}"

    alerts = Lakeraven::EHR::ClinicalDecisionSupportService.evaluate_patient(DEMO_PATIENT_ONE).alerts_by_category("preventive-care")

    assert_equal due.map { |r| "#{r[:name]} is due" }.sort, alerts.map { |a| a[:message] }.sort
  end
end
