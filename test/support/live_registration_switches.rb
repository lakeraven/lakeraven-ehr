# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration_parameters"

# For live tests (LIVE_RPMS=1 LIVE_RPMS_WRITES=1, a throwaway container only):
# the signed-on division's registration switches, REGISTRATION PARAMETERS
# (#9009061) fields 1 to 28 (#981), filed through DDR FILER as a site
# manager's edit would leave them, and put back after. The build's demo
# division answers NO to most "Ask for ..." switches, so a live test of a
# section the screens now hide on NO turns its switch on first.
module LiveRegistrationSwitches
  module_function

  # Turns the named switches to YES; returns what they were, for put_back.
  def turn_on(*switches) = set(switches.to_h { |switch| [ switch, true ] })

  # Files the switches ({ next_of_kin: true, ... }; nil clears one) and
  # returns their values before.
  def set(values)
    LiveRpmsSession.sign_on!
    client = RpmsRpc.client
    facility = client.division[:ien]
    before = RpmsRpc::RegistrationParameters.for_facility(facility)[:switches].slice(*values.keys)
    rows = values.map do |switch, on|
      field = RpmsRpc::RegistrationParameters::SWITCHES.fetch(switch)
      { file: RpmsRpc::RegistrationParameters::FILE, field: field, iens: "#{facility},", value: code(field, on) }
    end
    filed = client.with_context(RpmsRpc::RegistrationParameters::CONTEXT) { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
    raise "DDR FILER did not file the registration switches #{values.inspect}: #{filed.inspect}" unless filed && filed[:success]

    before
  end

  def put_back(before)
    set(before) if before.present?
  end

  # Field 2101 is a 0/1 set of codes; the others are Y/N. "@" deletes.
  def code(field, on)
    return "@" if on.nil?

    field == "2101" ? (on ? "1" : "0") : (on ? "Y" : "N")
  end
end
