# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (lakeraven-ehr#983): a site manager holding DGPF MANAGER defines a
# Clinical local record flag on a real RPMS, FileMan is read back, and the flag
# is inactivated; a user without the key is refused. It WRITES, so it runs only
# against a throwaway container and only when asked twice: LIVE_RPMS=1 and
# LIVE_RPMS_WRITES=1.
#
# The demo build gives DGPF MANAGER to no persona that can sign on to the app,
# so setup files the key on the run's persona through FileMan (NEW PERSON
# #200.051, whose cross-reference sets ^XUSEC) before it signs in, and
# teardown removes it. LIVE_RPMS_CLERK_* is a user without the key.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PRSUP123 LIVE_RPMS_VERIFY='PRSUP123!!' \
#   LIVE_RPMS_CLERK_ACCESS=PREG123 LIVE_RPMS_CLERK_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_setup_local_flags_test.rb
class LiveRegistrationSetupLocalFlagsTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr/registration/setup/local_flags"
  CONTEXT = "CIAV VUECENTRIC"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    LiveRpmsSession.sign_on!
    @duz = RpmsRpc.client.duz.to_i
    @key = key_ien("DGPF MANAGER")
    @granted = !held?(@key)
    fileman_write("ADD", [ { file: "200.051", field: ".01", iens: "+1,#{@duz},", value: @key.to_s } ], iens: { 1 => @key }) if @granted
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    LiveRpmsSession.sign_on!
    fileman_write("EDIT", [ { file: "200.051", field: ".01", iens: "#{@key},#{@duz},", value: "@" } ]) if @granted
  end

  def scoped(&) = RpmsRpc.client.with_context(CONTEXT, &)

  def key_ien(name)
    listed = scoped { RpmsRpc::DdrFileman.lister(file: "19.1", fields: "@;.01", flags: "IP", screen: "I $P(^(0),U)=\"#{name}\"") }
    listed[:entries].first.fetch(:ien).to_i
  end

  def held?(key)
    listed = scoped { RpmsRpc::DdrFileman.lister(file: "200.051", iens: ",#{@duz},", fields: "@;.01I", flags: "IP") }
    listed[:entries].any? { |entry| entry[:ien].to_i == key }
  end

  def fileman_write(mode, rows, iens: {})
    filed = scoped { RpmsRpc::DdrFileman.filer(mode: mode, rows: rows, iens: iens) }
    assert filed[:success], filed.inspect
  end

  # The #26.11 entry as FileMan holds it, re-signed as the run's persona.
  def fileman_flag(ien)
    LiveRpmsSession.sign_on!
    reply = scoped { RpmsRpc::DdrFileman.gets_entry(file: "26.11", iens: "#{ien},", fields: ".01;.02;.03;.04;.05", flags: "I") }
    sign_in_as_manager
    %w[.01 .02 .03 .04 .05].map { |field| reply[:fields].dig(field, :internal).to_s }
  end

  def sign_in_as_manager
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  def type_option(name)
    get "#{BASE}/new"
    css_select("#local_flag_type_ien option").find { |option| option.text == name }
  end

  test "#983 a Clinical flag with a 365-day review and 30-day notice is defined, read back from RPMS, then inactivated" do
    sign_in_as_manager
    clinical = type_option("Clinical")
    assert clinical, "the flag types include Clinical"
    name = "LIVE CLINICAL #{Time.now.strftime('%H%M%S')}"

    post BASE, params: { local_flag: { name: name, type_ien: clinical["value"], active: "1", review_days: "365",
                                       notification_days: "30", description: "Reviewed every year." } }
    assert_response :redirect, flash[:alert].to_s
    get BASE
    row = css_select("#local-flag-table tr[data-flag]").find { |tr| tr.at_css("td").text.strip == name }
    assert row, "#{name} is listed"
    ien = row["data-flag"].to_i
    assert_equal [ name, "1", clinical["value"], "365", "30" ], fileman_flag(ien)

    post "#{BASE}/#{ien}", params: { local_flag: { name: name, type_ien: clinical["value"], active: "0", review_days: "365",
                                                   notification_days: "30", description: "Reviewed every year.",
                                                   reason: "No longer used." } }
    assert_response :redirect, flash[:alert].to_s
    assert_equal [ name, "0", clinical["value"], "365", "30" ], fileman_flag(ien), "inactivated, not deleted"

    get "#{BASE}/#{ien}/edit"
    assert_select "#local-flag-history li", text: /No longer used\./
    assert_select "#local-flag-history li", text: /New Local Patient Record Flag entered\./
  end

  test "#983 the Behavioral type is not offered, and a Behavioral flag is refused with nothing filed" do
    sign_in_as_manager
    get "#{BASE}/new"
    offered = css_select("#local_flag_type_ien option").map(&:text)
    refute_includes offered, "Behavioral"
    assert_includes offered, "Clinical"

    LiveRpmsSession.sign_on!
    behavioral = RpmsRpc::RegistrationSetup.flag_types.find { |type| type[:name] == "BEHAVIORAL" }
    sign_in_as_manager
    name = "LIVE BEHAVIORAL #{Time.now.strftime('%H%M%S')}"
    post BASE, params: { local_flag: { name: name, type_ien: behavioral[:ien], active: "1", review_days: "0", notification_days: "0" } }
    assert_response :unprocessable_content
    get BASE
    refute(css_select("#local-flag-table tr[data-flag] td").any? { |td| td.text.strip == name })
  end

  test "#983 a user without DGPF MANAGER is refused the page and cannot define a flag" do
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_CLERK_ACCESS"), password: ENV.fetch("LIVE_RPMS_CLERK_VERIFY") }
    get BASE
    assert_response :forbidden
    post BASE, params: { local_flag: { name: "LIVE REFUSED", type_ien: "3", review_days: "0", notification_days: "0" } }
    assert_response :forbidden
  end
end
