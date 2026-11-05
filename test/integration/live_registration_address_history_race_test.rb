# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-REG-21.1, S-REG-20.2): the front-desk persona changes a
# patient's address and records race and ethnicity on a real RPMS, through the
# screens, then reads FileMan back (DDR GETS ENTRY DATA), not the app's answer.
# It WRITES synthetic seed patients, so it runs only against a throwaway
# container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9154 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_address_history_race_test.rb
class LiveRegistrationAddressHistoryRaceTest < ActionDispatch::IntegrationTest
  ADDRESS_DFN = 990_011 # KILO,AVERY, a synthetic seed patient
  RACE_DFN = 990_012    # LIMA,REESE, a synthetic seed patient

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def fileman(file, iens, fields)
    reply = RpmsRpc.client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: "I")
    end
    assert reply && !reply[:error], "DDR GETS ENTRY DATA on ##{file} #{iens}: #{reply.inspect}"
    reply[:fields].transform_values { |f| f[:internal].to_s }
  end

  def address_form(dfn)
    get "/lakeraven-ehr/registration/patients/#{dfn}/address/edit"
    assert_response :ok
    css_select("#address-form").first.css("input[name^='address['], select[name^='address[']").to_h do |input|
      value = input.name == "select" ? input.css("option[selected]").first&.[]("value") : input["value"]
      [ input["name"][/\[(\w+)\]/, 1], value.to_s ]
    end
  end

  test "S-REG-21.1 a new address is saved and the old one is kept, ended on the date the patient moved" do
    old = fileman("2", "#{ADDRESS_DFN},", ".111;.114;.115;.131")
    moved = Date.current # not before the date this address began, which an earlier run may have set to today
    # Never what is on file, even when an earlier run did not restore it.
    street = old[".111"] == "11 LIVE HISTORY RD" ? "12 LIVE HISTORY RD" : "11 LIVE HISTORY RD"
    form = address_form(ADDRESS_DFN)

    patch "/lakeraven-ehr/registration/patients/#{ADDRESS_DFN}/address",
          params: { address: form.merge("address_line1" => street, "moved_on" => moved.iso8601) }

    assert_redirected_to "/lakeraven-ehr/registration/patients/#{ADDRESS_DFN}"
    assert_equal street, fileman("2", "#{ADDRESS_DFN},", ".111")[".111"]
    newest = RpmsRpc.client.with_context("CIAV VUECENTRIC") { RpmsRpc::Registration.address_history(ADDRESS_DFN) }.first
    assert_equal({ ".02" => old[".111"], ".05" => old[".114"], ".06" => old[".115"], ".08" => old[".131"],
                   ".12" => RpmsRpc::FilemanDateParser.to_fileman(moved) },
                 fileman("9000001.83", "#{newest[:ien]},#{ADDRESS_DFN},", ".02;.05;.06;.08;.12"))

    get "/lakeraven-ehr/registration/patients/#{ADDRESS_DFN}"
    assert_select "#address-history tr[data-address-history='#{newest[:ien]}']", text: /#{Regexp.escape(old['.111'])}/
  ensure
    if old
      patch "/lakeraven-ehr/registration/patients/#{ADDRESS_DFN}/address",
            params: { address: address_form(ADDRESS_DFN).merge("address_line1" => old[".111"]) }
    end
  end

  test "S-REG-20.2 races and ethnicities are saved with how each was collected" do
    choices = RpmsRpc.client.with_context("CIAV VUECENTRIC") { RpmsRpc::Registration.race_ethnicity_choices }
    native = choices[:races].find { |r| r[:name] == "AMERICAN INDIAN OR ALASKA NATIVE" }[:ien]
    white = choices[:races].find { |r| r[:name] == "WHITE" }[:ien]
    not_hispanic = choices[:ethnicities].find { |e| e[:name] == "NOT HISPANIC OR LATINO" }[:ien]
    self_id = choices[:methods].find { |m| m[:name] == "SELF IDENTIFICATION" }[:ien]
    proxy = choices[:methods].find { |m| m[:name] == "PROXY" }[:ien]

    get "/lakeraven-ehr/registration/patients/#{RACE_DFN}/race_ethnicity/edit"
    assert_response :ok
    post "/lakeraven-ehr/registration/patients/#{RACE_DFN}/race_ethnicity",
         params: { race_ethnicity: { races: { native.to_s => { chosen: "1", method: self_id.to_s },
                                              white.to_s => { chosen: "1", method: proxy.to_s } },
                                     ethnicities: { not_hispanic.to_s => { chosen: "1", method: self_id.to_s } } } }

    assert_redirected_to "/lakeraven-ehr/registration/patients/#{RACE_DFN}#race-ethnicity-section"
    assert_equal({ ".01" => native.to_s, ".02" => self_id.to_s }, fileman("2.02", "#{native},#{RACE_DFN},", ".01;.02"))
    assert_equal({ ".01" => white.to_s, ".02" => proxy.to_s }, fileman("2.02", "#{white},#{RACE_DFN},", ".01;.02"))
    assert_equal({ ".01" => not_hispanic.to_s, ".02" => self_id.to_s }, fileman("2.06", "#{not_hispanic},#{RACE_DFN},", ".01;.02"))

    get "/lakeraven-ehr/registration/patients/#{RACE_DFN}"
    assert_select "#race-ethnicity-section [data-field='races']", text: /White\s*\(proxy\)/
  end
end
