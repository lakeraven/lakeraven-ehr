# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-15, lakeraven-ehr#984): the development operator, who
# holds SDZSUP, changes DEMO PODIATRY's settings through the screens, and each
# is read back from HOSPITAL LOCATION (#44) or CLINIC SETUP PARAMETERS
# (#9009017.2) with DDR GETS ENTRY DATA. It WRITES, so it runs only against a
# throwaway container and only when asked twice; each test puts the clinic back.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_clinic_settings_test.rb
class LiveSchedulingClinicSettingsTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  CLINIC = "DEMO PODIATRY"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "SYS123", password: "RPMS.000" }
    @clinic = clinic_path(CLINIC)
    @ien = clinic_ien(CLINIC)
    @before = RpmsRpc::SchedulingSetup.clinic_settings(@ien)
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    LiveRpmsSession.sign_on!
    RpmsRpc::SchedulingSetup.update_clinic_settings(@ien, @before.slice(:length_minutes, :max_future_days)) if @before
  end

  test "S-SCH-15.1 the supervisor changes the length of appointment and future-booking days, and #44 holds both" do
    length = @before[:length_minutes] == 60 ? 30 : 60
    get "#{@clinic}/settings/edit"
    assert_response :ok
    form = settings_form

    post "#{@clinic}/settings", params: form.merge("settings[length_minutes]" => length.to_s, "settings[max_future_days]" => "45")
    assert_response :redirect, flash[:alert].to_s
    follow_redirect!
    assert_select "dd[data-setting='length_minutes']", text: length.to_s

    assert_equal [ length.to_s, "45" ], hospital_location(@ien, "1912;2002").values_at("1912", "2002"),
                 "#44 LENGTH OF APP'T and MAX # DAYS FOR FUTURE BOOKING"
  end

  test "S-SCH-15.6 and 15.7 a booking past the new limit is refused, names it, and needs no new sign-on" do
    assert_equal({ success: true }, RpmsRpc::SchedulingSetup.update_clinic_settings(@ien, max_future_days: 45))
    holidays = RpmsRpc::SchedulingSetup.holidays(start_date: Date.today + 50, end_date: Date.today + 70).map { |h| h[:date] }
    day = Date.today + 50
    day += 1 while day.saturday? || day.sunday? || holidays.include?(day)

    post "#{@clinic}/appointments", params: { booking: { patient_dfn: "3", start: "#{day.iso8601}T09:00", length: "30", note: "" } }

    assert_response :conflict
    assert_select ".alert", text: /#{CLINIC} books at most 45 days ahead, through #{(Date.today + 45).strftime('%b %-d, %Y')}/
    assert_empty clinic_appointments(@ien, wall(day, "09:00")), "nothing is filed on #44"
  end

  test "S-SCH-15.3 create visit at check-in with a provider required and no default provider warns, and is saved" do
    assert(@before[:providers].none? { |p| p[:default] }, "#{CLINIC} has no default provider to start with")
    setup_entry = @before[:setup_entry]
    get "#{@clinic}/settings/edit"
    form = settings_form

    begin
      post "#{@clinic}/settings", params: form.merge("settings[create_visit_at_checkin]" => "1", "settings[visit_provider_required]" => "1")
      assert_response :redirect, flash[:alert].to_s
      follow_redirect!
      assert_select "#default-provider-warning", text: /no default provider/

      assert_equal %w[1 1], setup_parameters(@ien, ".09;.14").values_at(".09", ".14"), "#9009017.2 CREATE VISIT AT CHECK-IN and VISIT PROVIDER REQUIRED"
    ensure
      if setup_entry
        RpmsRpc::SchedulingSetup.update_clinic_settings(@ien, @before.slice(:create_visit_at_checkin, :visit_provider_required).transform_values { |v| v ? true : false })
      else
        remove_setup_entry(@ien)
      end
    end
  end

private

# The edit form's values as the browser would post them: a check box only
# when it is checked (Rails' hidden "0" before it stands otherwise).
def settings_form
  css_select("#settings-form input, #settings-form select").each_with_object({}) do |input, form|
    name = input["name"].to_s
    next unless name.start_with?("settings[")
    next if input["type"] == "checkbox" && !input["checked"]

    form[name] = input.name == "select" ? input.at_css("option[selected]")&.[]("value").to_s : input["value"].to_s
  end
end

  def hospital_location(ien, fields) = gets_internal(44, ien, fields)

  def setup_parameters(ien, fields) = gets_internal("9009017.2", ien, fields)

  def gets_internal(file, ien, fields)
    got = in_chart_context { RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "I") }
    assert got && !got[:error], "##{file} #{ien}: #{got.inspect}"
    got[:fields].transform_values { |v| v[:internal].to_s }
  end

  # The test added the clinic's CLINIC SETUP PARAMETERS entry; take it away again.
  def remove_setup_entry(ien)
    in_chart_context { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "9009017.2", field: ".01", iens: "#{ien},", value: "@" } ]) }
  end
end
