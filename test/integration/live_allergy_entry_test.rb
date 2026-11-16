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
    sign_in("PRN123", "PRN123!!")
    open_chart(PATIENT)
    assert_select "a[href='/lakeraven-ehr/patients/#{PATIENT}/allergies/new']", text: "Record an allergy"
    get "/lakeraven-ehr/patients/#{PATIENT}/allergies/new"
    assert_response :ok
    %w[allergy[agent_pointer] allergy[originated_at] allergy[symptoms][][ien]].each do |name|
      assert_select "input[name=?]", name, { count: 0 }, "the form asks for no RPMS value (#{name})"
    end

    # Search for the allergen and pick one RPMS offers that the patient has no entry for yet.
    agent_choice = unused_allergen_choice
    agent, pointer = agent_choice.split("^", 2).reverse
    # Search the symptom catalog and pick RASH.
    get "/lakeraven-ehr/patients/#{PATIENT}/allergies/new", params: { symptom_search: "RAS" }
    symptom_choice = css_select("input[type=radio][name='allergy[symptom_choice]']").map { |i| i["value"] }.find { |v| v.end_with?("^RASH") }
    flunk "Find symptom RAS offered no RASH" unless symptom_choice

    # The pickers' values, on the site's clock.
    entered = Lakeraven::EHR::SiteTime.now - 3600
    reaction_day = Lakeraven::EHR::SiteTime.today - 2
    post "/lakeraven-ehr/patients/#{PATIENT}/allergies", params: { authenticity_token: csrf, allergy: {
      agent_choice: agent_choice, type: "D", nature: "A", observed_or_historical: "h",
      originated_on: entered.strftime("%Y-%m-%dT%H:%M"), reaction_on: reaction_day.iso8601,
      symptom_choice: symptom_choice, symptom_on: reaction_day.iso8601
    } }
    assert_response :redirect, css_select("[role='alert']").map(&:text).join(" ").squish
    follow_redirect!
    assert_match "Allergy recorded.", response.body

    LiveRpmsSession.sign_on!
    row = ciav { RpmsRpc::Allergy.for_patient(PATIENT) }.find { |r| r[:allergen].to_s.casecmp?(agent) }
    flunk "ORQQAL LIST for #{PATIENT} lists no #{agent}" unless row
    fields = ciav { RpmsRpc::DdrFileman.gets_entry(file: "120.8", iens: "#{row[:ien]},", fields: ".01;.02;1;3.1;4;5", flags: "IE") }[:fields]
    warn "[live S-TRI-04.2] #120.8 #{row[:ien]}: #{fields.inspect}"
    assert_equal PATIENT.to_s, fields.dig(".01", :internal), "the patient"
    assert_equal agent, fields.dig(".02", :external), "the reactant, as the search named it"
    assert_equal pointer, fields.dig("1", :internal), "the allergen's pointer, as the search gave it"
    assert_equal RpmsRpc::FilemanDateParser.format_datetime(entered), fields.dig("4", :internal).to_s.ljust(12, "0"),
                 "the entry time picked, on the site's clock"
    assert_equal NURSE_DUZ, fields.dig("5", :internal), "originated by PROFILE,RN"
    assert_equal "D", fields.dig("3.1", :internal), "a drug allergy"
    reaction = ciav { RpmsRpc::DdrFileman.gets_entry(file: "120.81", iens: "1,#{row[:ien]},", fields: ".01;3", flags: "IE") }
    warn "[live S-TRI-04.2] #120.81 1,#{row[:ien]}: #{reaction.inspect}"
    assert_equal symptom_choice.split("^").first, reaction[:fields].dig(".01", :internal), "the symptom picked"
    assert_equal RpmsRpc::FilemanDateParser.format_date(reaction_day), reaction[:fields].dig("3", :internal).to_s[0, 7],
                 "the symptom date picked"
  end

  private

  # A match from the form's own allergen search that the patient has no
  # entry for yet. Searches a few starting texts, through the app.
  def unused_allergen_choice
    LiveRpmsSession.sign_on!
    on_file = ciav { RpmsRpc::Allergy.for_patient(PATIENT) }.map { |r| r[:allergen].to_s.upcase }
    sign_in("PRN123", "PRN123!!")
    open_chart(PATIENT)
    %w[AMOXICILLIN AMPICILLIN CEPHALEXIN DOXYCYCLINE ERYTHROMYCIN TETRACYCLINE].each do |text|
      get "/lakeraven-ehr/patients/#{PATIENT}/allergies/new", params: { allergen_search: text }
      assert_response :ok
      choice = css_select("input[type=radio][name='allergy[agent_choice]']").map { |i| i["value"] }
                 .find { |value| value.include?(";PSNDF(50.6,^") && !on_file.include?(value.split("^", 2).last.upcase) }
      return choice if choice
    end
    flunk "no allergen from the form's search that #{PATIENT} does not already have"
  end
end
