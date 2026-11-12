# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-10): the scheduler persona keeps a clinic's wait list on a
# real RPMS, and FileMan is read back. The demo build has no list
# (openrpms#1083), so the test makes one. It WRITES, so it runs only against a
# throwaway container and only when asked twice.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_wait_list_test.rb
class LiveSchedulingWaitListTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  PATIENT = 990_002 # a demo patient
  CLINIC = "DEMO IHS CLINIC"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    @list = ensure_list
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    @base = "#{clinic_path(CLINIC)}/wait_list"
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def ensure_list
    LiveRpmsSession.sign_on!
    clinic = clinic_ien(CLINIC)
    found = RpmsRpc::WaitList.lists.find { |list| list[:clinic_ien] == clinic }
    return found[:ien] if found

    filed = in_chart_context { RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [ { file: "9009017.1", field: ".01", iens: "+1,", value: clinic.to_s } ]) }
    assert filed[:success], filed.inspect
    filed[:iens][1].to_i
  end

  def filed(entry, fields)
    LiveRpmsSession.sign_on!
    reply = in_chart_context { RpmsRpc::DdrFileman.gets_entry(file: "9009017.11", iens: "#{entry},#{@list},", fields: fields, flags: "I") }
    values = reply[:fields].transform_values { |value| value[:internal] }
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    values
  end

  def add(recall: Date.today + 14)
    reason = css_select("select[name='wait_list[reason_ien]'] option").map { |o| o["value"] }.reject(&:empty?).first
    post @base, params: { wait_list: { patient_dfn: PATIENT, added_on: Date.today.iso8601, reason_ien: reason, priority: "1", recall_on: recall.iso8601 } }
    assert_response :redirect, flash[:alert].to_s
    follow_redirect!
    css_select("#wait-list tr[data-patient='#{PATIENT}'][data-open='true']").last["data-entry"].to_i
  end

  test "S-SCH-10.1, 10.5 and 10.9 a patient goes on the list, shows in the recall range, and comes off with a resolution" do
    get "#{@base}/new"
    assert_response :ok
    entry = add

    assert_equal({ ".01" => PATIENT.to_s, ".02" => "1", ".04" => "208" }, filed(entry, ".01;.02;.04"))

    get @base, params: { from: Date.today.iso8601, to: (Date.today + 30).iso8601 }
    assert_select "#wait-list tr[data-entry='#{entry}']"
    get @base, params: { from: (Date.today + 60).iso8601 }
    assert_select "#wait-list tr[data-entry='#{entry}']", 0

    get "#{@base}/#{entry}/removal"
    resolution = css_select("select[name='removal[resolution_ien]'] option").map { |o| o["value"] }.reject(&:empty?).first
    post "#{@base}/#{entry}/removal", params: { removal: { removed_on: "", resolution_ien: resolution } }
    assert_response :unprocessable_content

    post "#{@base}/#{entry}/removal", params: { removal: { removed_on: Date.today.iso8601, resolution_ien: resolution } }
    assert_response :redirect
    assert_equal({ ".08" => resolution, ".11" => "208" }, filed(entry, ".08;.11"))

    get @base
    assert_select "#wait-list tr[data-entry='#{entry}']", 0
    get @base, params: { open: "0" }
    assert_select "#wait-list tr[data-entry='#{entry}'][data-open='false']"
  end

  test "S-SCH-10.7 booking from the list files the appointment and closes the entry" do
    get "#{@base}/new"
    entry = add
    clinic = clinic_path(CLINIC)
    day = weekday_ahead(from: 7, spread: 14)
    time = open_time(clinic, day)

    post "#{@base}/#{entry}/booking", params: { booking: { start: "#{day.iso8601}T#{time}", length: "15" } }
    assert_response :redirect, flash[:alert].to_s

    made = RpmsRpc::WaitList.reasons("R").find { |r| r[:name] == "APPOINTMENT MADE" }
    assert_equal made[:ien].to_s, filed(entry, ".08")[".08"]
    follow_redirect!
    get clinic, params: { date: day.iso8601 }
    assert_select "#appointments tr[data-patient='#{PATIENT}'] td[data-status='booked']"
  end
end
