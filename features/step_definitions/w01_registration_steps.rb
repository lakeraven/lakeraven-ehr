# frozen_string_literal: true

# Steps for features/bprm_twin/w01_registration/ (rpms-ux W01, lakeraven-ehr#565).
#
# Every broker reply here is seeded on RpmsRpc.mock! the way rpms-rpc's own
# tests seed it (test/rpms_rpc/api/registration_test.rb, ddr_fileman_test.rb
# at the pinned ref), keyed by the exact param the gem builds, so a drift in
# the gem's wire contract breaks these steps rather than passing beneath
# them. The Then steps assert what was SENT to RPMS and what the page says;
# nothing reads FileMan back (mock evidence, #484).

require "rpms_rpc/api/registration"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"

module W01RegistrationHelpers
  # AGG recordset replies, framed as the gem's tests frame them
  # (typed header row, $C(30) records, $C(31) end).
  def agg_add_reply(dfn:, result: "1", message: "")
    "I00010RESULT^T00080MESSAGE^I00010DFN\x1e#{result}^#{message}^#{dfn}\x1e\x1f"
  end

  def agg_update_reply(result: "1", error: "")
    "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e#{result}^#{error}^\x1e\x1f"
  end

  def parms_of(call)
    call[:params][2].to_s.split(RpmsRpc::Agg::PARM_DELIM)
  end

  def hrn_read_key(dfn:, facility:)
    RpmsRpc::DdrFileman.gets_entry_param(file: "9000001.41", iens: "#{facility},#{dfn},", fields: ".02").to_s
  end

  def registration_writes
    %w[AGG\ ADD\ NEW\ PATIENT AGG\ UPDATE\ PATIENT VAFC\ VOA\ ADD\ PATIENT DDR\ FILER]
      .flat_map { |rpc| received_rpc_calls(rpc) }
  end
end
World(W01RegistrationHelpers)

# -- Background -----------------------------------------------------------------

Given("RPMS has the AG registration service") do
  # Agg.available? asks CIANBRPC CANRUN for AGG ADD NEW PATIENT under AGGRPC.
  RpmsRpc.client.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")
end

Given("the tribe list holds {string} as tribe {int}") do |name, ien|
  key = RpmsRpc::DdrFileman.lister_param(file: "9999999.03", fields: ".01", max: "*").to_s
  RpmsRpc.client.seed(:ddr_lister, key, "[Data]\n#{ien}^#{name}")
end

# -- S-REG-02 ---------------------------------------------------------------------

Given("no chart exists for {string}") do |name|
  found = Lakeraven::EHR::Patient.search(name.split(",").first)
  assert_empty found.select { |p| p.name.to_s.casecmp?(name) }, "a chart already exists for #{name}"
end

Given("RPMS will file the next new patient as record {int}") do |dfn|
  @expected_dfn = dfn
  RpmsRpc.client.seed(:agg_add_patient, RpmsRpc::Agg::DEFAULT_WINDOW, agg_add_reply(dfn: dfn))
  RpmsRpc.client.seed(:agg_update_patient, RpmsRpc::Agg::DEFAULT_WINDOW, agg_update_reply)
  # The completion pass (tribe, community) files through DDR FILER under the
  # ^DPT(DFN) lock.
  RpmsRpc.client.seed(:ddr_lock_unlock_node, RpmsRpc::DdrFileman.lock_param(node: "^DPT(#{dfn})").to_s, true)
  RpmsRpc.client.seed(:ddr_lock_unlock_node, RpmsRpc::DdrFileman.unlock_param(node: "^DPT(#{dfn})").to_s, true)
  RpmsRpc.client.seed(:ddr_filer, "EDIT", "[Data]")
end

When("I register a patient with:") do |table|
  visit engine_path("/registration/patients/new")
  table.rows_hash.each do |label, value|
    if page.has_select?(label)
      select value, from: label
    else
      fill_in label, with: value
    end
  end
  click_button "Register patient"
end

Then("RPMS was sent a new patient {string}, female, born {}, on the AG registration path") do |name, dob|
  add = received_rpc_calls("AGG ADD NEW PATIENT").first
  assert add, "AGG ADD NEW PATIENT was not called"
  assert_equal "AGGRPC", add[:context], "the AG write must run under the AGGRPC context"
  window, dfn, = add[:params]
  assert_equal RpmsRpc::Agg::DEFAULT_WINDOW, window
  assert_equal "", dfn, "a new patient is sent with no DFN"
  last, first = name.split(",", 2)
  pairs = parms_of(add)
  assert_includes pairs, "AGGPTLNM=#{last}"
  assert_includes pairs, "AGGPTFNM=#{first}"
  assert_includes pairs, "AGGPTSEX=FEMALE"
  assert_includes pairs, "AGGPTDOB=#{dob}"
end

Then("health record number {int} was filed for record {int}") do |hrn, dfn|
  update = received_rpc_calls("AGG UPDATE PATIENT").first
  assert update, "AGG UPDATE PATIENT was not called"
  assert_equal dfn.to_s, update[:params][1]
  assert_includes parms_of(update), "AGGPTHRN=#{hrn}"
end

Then("tribe {int} and community {string} were filed on IHS PATIENT \\(#9000001) record {int}") do |tribe, community, dfn|
  filer = received_rpc_calls("DDR FILER").last
  assert filer, "DDR FILER was not called for the IHS completion fields"
  assert_equal "EDIT", filer[:params][0]
  rows = filer[:params][1].values
  assert_includes rows, "9000001^1108^#{dfn},^#{tribe}"
  assert_includes rows, "9000001^1118^#{dfn},^#{community}"
end

Then("the page says {string} is registered with health record number {int}") do |name, hrn|
  assert page.has_css?("[role=status]", text: "Patient registered"), page.text
  assert page.has_content?("#{name} is filed in RPMS as record #{@expected_dfn} with health record number #{hrn}"), page.text
end

Then("the registration is refused, naming {string}") do |value|
  assert_equal 422, page.status_code
  assert page.has_css?("[role=alert]", text: "The registration was refused"), page.text
  assert page.has_css?("[role=alert] li", text: value), page.text
end

Then("no registration write was sent to RPMS") do
  assert_empty registration_writes.map { |c| c[:rpc] }
end

# -- S-REG-01 ---------------------------------------------------------------------

Given("the signed-on user's facility is {int}") do |ien|
  # BEHOSICX SITEINFO, the current division (DUZ(2)); the HRN is per facility.
  RpmsRpc.client.seed_lines(:site_info, "", { domain: "EXAMPLE.IHS.GOV", name: "EXAMPLE HEALTH CENTER",
                                              abbreviation: "EX", state: "WASHINGTON", address: "1 EXAMPLE RD",
                                              city: "EXAMPLE", zip: "99999", ien: ien })
end

Given("{string}, record {int}, has health record number {string} at facility {int}") do |name, dfn, hrn, facility|
  patient = Lakeraven::EHR::Patient.find_by_dfn(dfn)
  assert patient && patient.name == name, "the test_helper seeds no patient #{dfn} named #{name}"
  RpmsRpc.client.seed(:ddr_gets_entry_data, hrn_read_key(dfn: dfn, facility: facility),
                      "[Data]\n9000001.41^#{facility},#{dfn},^.02^#{hrn}^#{hrn}")
end

When("I search for {string} born {string}") do |name, dob|
  visit engine_path("/registration/patients")
  fill_in "Last name, or LAST,FIRST", with: name
  fill_in "Date of birth", with: dob
  click_button "Search"
end

When("I search for {string}") do |name|
  visit engine_path("/registration/patients")
  fill_in "Last name, or LAST,FIRST", with: name
  click_button "Search"
end

Then("{string} is listed with health record number {string}") do |name, hrn|
  row = page.find("tr", text: name)
  assert row.has_content?(hrn), "row for #{name} does not show HRN #{hrn}: #{row.text}"
end

Then("I can open their registration, which shows health record number {string}") do |hrn|
  click_link "Open registration"
  assert page.has_css?("h1", text: "Registration"), page.text
  assert page.has_css?("dd", text: hrn), page.text
end

Then("I am told no patient matches") do
  assert page.has_css?("[role=status]", text: "No patient matches"), page.text
end

Then("I am offered to add a new patient") do
  assert page.has_link?("Add a new patient"), page.text
  click_link "Add a new patient"
  assert page.has_css?("h1", text: "Register a new patient"), page.text
end
