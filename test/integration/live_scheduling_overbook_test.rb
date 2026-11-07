# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-01.10, lakeraven-ehr#603): the scheduler persona, who
# holds the overbook right on DEMO IHS CLINIC, books a full time as an
# overbook, and OVERBOOK (#44.003 field 9) is read back from FileMan. It
# WRITES, so it runs only against a throwaway container and only when asked
# twice.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_overbook_test.rb
class LiveSchedulingOverbookTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  OTHER_PATIENT = 990_001 # ALPHA,CASEY, a demo patient

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-01.2 and 01.10 a full time is offered as an overbook, and once confirmed it is on the clinic marked OVERBOOK" do
    clinic = clinic_path("DEMO IHS CLINIC")
    day = weekday_ahead(from: 30, spread: 30)
    block = add_one_slot_block(day)

    begin
      book(clinic, day, "17:00", dfn: OTHER_PATIENT)
      get clinic, params: { date: day.iso8601 }
      assert_select "#open-times tr[data-time='17:00'] td[data-open='0']"
      assert_select "#open-times tr[data-time='17:00'] a[data-overbook]", text: "Overbook"

      params = { booking: { patient_dfn: "3", start: "#{day.iso8601}T17:00", length: "15", note: "" } }
      post "#{clinic}/appointments", params: params
      assert_response :conflict
      assert_select "#overbook-offer"
      refute(clinic_appointments(clinic_ien("DEMO IHS CLINIC"), wall(day, "17:00")).any? { |r| r[:patient] == "3" }, "nothing filed before the scheduler confirms")

      post "#{clinic}/appointments", params: params.merge(overbook: "1")
      assert_response :redirect, flash[:alert].to_s
      follow_redirect!
      assert_select "#clinic-alert", count: 0

      entries = clinic_appointments(clinic_ien("DEMO IHS CLINIC"), wall(day, "17:00"))
      assert_equal "O", entries.find { |r| r[:patient] == "3" }&.dig(:overbook), "#44.003 OVERBOOK on the overbook"
      assert_equal "", entries.find { |r| r[:patient] == OTHER_PATIENT.to_s }&.dig(:overbook), "the booking that filled the slot is not an overbook"
    ensure
      bsdx("BSDX CANCEL AVAILABILITY", block.to_s)
    end
  end

  private

  def bsdx(rpc, *params)
    client = RpmsRpc.client
    Array(client.with_context("BSDXRPC") { client.call_rpc_global_array(rpc, *params) }).join
  end

  # A 17:00-18:00 block of one slot on DEMO IHS CLINIC, of an access type that allows booking.
  def add_one_slot_block(date)
    type = RpmsRpc::SchedulingSetup.access_types.find { |t| !t[:inactive] && !t[:prevent_access] }.fetch(:id)
    on = date.strftime("%m-%d-%Y")
    reply = bsdx("BSDX ADD NEW AVAILABILITY", "#{on}@1700", "#{on}@1800", type.to_s, "DEMO IHS CLINIC", "1", "")
    id = reply[/(\d+)\^-1/, 1]
    assert id && id.to_i.positive?, "BSDX ADD NEW AVAILABILITY: #{reply.inspect}"
    id.to_i
  end
end
