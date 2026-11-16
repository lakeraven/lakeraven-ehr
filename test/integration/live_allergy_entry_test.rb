# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_visit_helper"

# Live (rpms-ux S-TRI-04.2): on a real RPMS the nurse persona (PROVIDER),
# signed on through the app, is offered "Record an allergy" on the chart and
# records one the patient reports; PATIENT ALLERGIES (#120.8) is read back
# with FileMan. It WRITES, so it runs only against a throwaway container and
# only when asked twice:
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PRN123 LIVE_RPMS_VERIFY='PRN123!!' \
#   bin/rails test test/integration/live_allergy_entry_test.rb
class LiveAllergyEntryTest < ActionDispatch::IntegrationTest
  include LiveVisitHelper

  PATIENT = 990_041 # a synthetic seed patient no other live test files allergies on
  NURSE_DUZ = "205"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless live_writes?
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    next unless live_writes?

    ActionController::Base.allow_forgery_protection = @forgery_was
    LiveRpmsSession.sign_on!
  end

  test "S-TRI-04.2 the nurse records an allergy the patient reports, and RPMS holds it in PATIENT ALLERGIES" do
    agent = unused_agent
    sign_in("PRN123", "PRN123!!")
    open_chart(PATIENT)
    assert_select "a[href='/lakeraven-ehr/patients/#{PATIENT}/allergies/new']", text: "Record an allergy"
    get "/lakeraven-ehr/patients/#{PATIENT}/allergies/new"
    assert_response :ok

    now = RpmsRpc::FilemanDateParser.format_datetime(Lakeraven::EHR::SiteTime.now)
    post "/lakeraven-ehr/patients/#{PATIENT}/allergies", params: { authenticity_token: csrf, allergy: {
      agent: agent[:name], agent_pointer: agent[:pointer], type: "D", nature: "A", originated_at: now,
      observed_or_historical: "h"
    } }
    assert_response :redirect, css_select("[role='alert']").map(&:text).join(" ").squish
    follow_redirect!
    assert_match "Allergy recorded.", response.body

    LiveRpmsSession.sign_on!
    row = ciav { RpmsRpc::Allergy.for_patient(PATIENT) }.find { |r| r[:allergen].to_s.casecmp?(agent[:name]) }
    flunk "ORQQAL LIST for #{PATIENT} lists no #{agent[:name]}" unless row
    fields = ciav { RpmsRpc::DdrFileman.gets_entry(file: "120.8", iens: "#{row[:ien]},", fields: ".01;.02;5;3.1", flags: "IE") }[:fields]
    warn "[live S-TRI-04.2] #120.8 #{row[:ien]}: #{fields.inspect}"
    assert_equal PATIENT.to_s, fields.dig(".01", :internal), "the patient"
    assert_equal agent[:name], fields.dig(".02", :external), "the reactant"
    assert_equal NURSE_DUZ, fields.dig("5", :internal), "originated by PROFILE,RN"
    assert_equal "D", fields.dig("3.1", :internal), "a drug allergy"
  end

  private

  # A GMR ALLERGIES (#120.82) agent the patient has no entry for yet.
  def unused_agent
    LiveRpmsSession.sign_on!
    on_file = ciav { RpmsRpc::Allergy.for_patient(PATIENT) }.map { |r| r[:allergen].to_s.upcase }
    entry = ciav { RpmsRpc::DdrFileman.lister(file: "120.82", fields: ".01", flags: "IP", max: "200") }[:entries]
            .find { |e| e[:pieces].first.to_s.present? && !on_file.include?(e[:pieces].first.to_s.upcase) }
    flunk "no unused #120.82 agent for #{PATIENT}" unless entry
    { name: entry[:pieces].first.to_s, pointer: "#{entry[:ien]};GMRD(120.82," }
  end
end
