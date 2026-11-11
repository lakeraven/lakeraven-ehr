# frozen_string_literal: true

require "test_helper"

# Demo prototype (#989, #990): a user who works referrals confirms or rejects
# a follow-up an outside app posted. Confirming writes it to the RPMS
# referral through BMC UPDATE REFERRAL and reads it back; rejecting writes
# nothing. Synthetic data; the broker is the mock, seeded by RcisFollowUpMock.
class ReferralFollowUpsTest < ActionDispatch::IntegrationTest
  include RcisFollowUpMock

  DFN = 3
  IEN = 7001
  REVIEWER = "PROFILE,MD"

  setup do
    seed_open_referral(dfn: DFN, ien: IEN)
    @follow_up = Lakeraven::EHR::AppFollowUp.create!(
      client_id: "outside-app-demo", app_name: "Stand-in outreach app", ai_generated: true,
      patient_dfn: DFN, referral_ien: IEN, reached: true, appointment_on: Date.new(2026, 12, 4),
      summary: "Patient says the cardiology appointment is booked for 12/4."
    )
  end

  def sign_in(keys = "referrals_user")
    post "/lakeraven-ehr/test_session", params: { duz: "206", user_type: "provider", user_name: REVIEWER, security_keys: keys }
  end

  def expected_note
    "Outside app Stand-in outreach app (AI-generated, confirmed by #{REVIEWER}): " \
      "Patient says the cardiology appointment is booked for 12/4. Appointment 12/04/2026."
  end

  test "the queue lists a pending follow-up with its patient, referral, app, AI label and outcome" do
    sign_in
    get "/lakeraven-ehr/referrals/follow_ups"

    assert_response :ok
    assert_select "#prototype-banner", text: /synthetic data/
    assert_select "#pending-follow-ups tr[data-follow-up='#{@follow_up.id}']" do
      assert_select "td", text: /Patient #{DFN}/
      assert_select "td", text: /RPMS referral #{IEN}/
      assert_select "td", text: /Stand-in outreach app/
      assert_select "td", text: /AI-generated/
      assert_select "td", text: /booked for 12\/4/
      assert_select "form[action='/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/confirm'] button", text: "Confirm"
      assert_select "form[action='/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/reject'] button", text: "Reject"
    end
    assert_empty bmc_update_calls
  end

  test "confirming writes the date and a case note to the RPMS referral, reads it back, and audits who did it" do
    seed_update_reply(ien: IEN)
    seed_read_back(ien: IEN, appointment: "3261204.12", note_text: expected_note)
    sign_in

    post "/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/confirm"
    follow_redirect!

    assert_response :ok
    calls = bmc_update_calls
    assert_equal 1, calls.size
    assert_equal IEN.to_s, calls.first[0]
    assert_equal "14^12/04/2026@12:00", calls.first[11]
    assert_equal expected_note, calls.first[29]
    @follow_up.reload
    assert @follow_up.confirmed?
    assert @follow_up.written_back?
    assert_equal [ "206", REVIEWER ], [ @follow_up.reviewed_by_duz, @follow_up.reviewed_by_name ]
    assert_select "#follow-up-notice", text: /Written to the RPMS referral and read back/
    assert_select "#read-back-#{@follow_up.id} [data-read-back='appointment']", text: "2026-12-04"
    assert_select "#read-back-#{@follow_up.id} [data-read-back='case_note']", text: expected_note
    actions = Lakeraven::EHR::AuditEvent.where(event_type: "application").order(:id).pluck(:action, :agent_who_identifier)
    assert_equal [ %w[U 206], %w[E 206] ], actions

    post "/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/confirm"
    assert_equal 1, bmc_update_calls.size, "a second confirm never files a second note"
  end

  test "rejecting writes nothing to RPMS" do
    sign_in
    post "/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/reject"
    follow_redirect!

    assert @follow_up.reload.rejected?
    assert_empty bmc_update_calls
    assert_select "#follow-up-notice", text: /Nothing was written to RPMS/
    assert_select "#reviewed-follow-ups tr[data-status='rejected']", text: /Not written/
  end

  test "a failed RPMS write shows its reason and can be retried" do
    seed_update_reply(ien: IEN, reply: "~`0^Error updating referral:The value is not valid.")
    sign_in
    post "/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/confirm"
    follow_redirect!

    assert @follow_up.reload.write_back_failed?
    assert_select "#follow-up-alert", text: /The value is not valid/
    assert_select "#reviewed-follow-ups [data-write-back-error]", text: /The value is not valid/
    assert_select "form[action='/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/retry']"

    seed_update_reply(ien: IEN)
    seed_read_back(ien: IEN, appointment: "3261204.12", note_text: expected_note)
    post "/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/retry"
    assert @follow_up.reload.written_back?
  end

  test "a user who does not work referrals is refused the queue" do
    sign_in("")
    get "/lakeraven-ehr/referrals/follow_ups"
    assert_response :forbidden
    post "/lakeraven-ehr/referrals/follow_ups/#{@follow_up.id}/confirm"
    assert_response :forbidden
    assert @follow_up.reload.pending?
  end
end
