# frozen_string_literal: true

# Steps for features/bprm_twin/w02_scheduling/ (rpms-ux W02, lakeraven-ehr#565).
# The broker reply is seeded on RpmsRpc.mock! as rpms-rpc's own scheduling
# tests seed it, keyed by the FileMan start time the gem sends; the Then steps
# assert what was SENT and what the page says (mock evidence, #484).

require "rpms_rpc/fileman_date_parser"

module W02SchedulingHelpers
  def booking_start(date, time)
    Time.zone.parse("#{date} #{time}")
  end

  def fileman(time)
    RpmsRpc::FilemanDateParser.to_fileman(time)
  end
end
World(W02SchedulingHelpers)

Given("a clinic resource {string} with an open slot on {string} at {string}") do |resource, date, time|
  # The mock has no slot model: the open slot is the precondition that the
  # booking reply below succeeds. A live broker would refuse a full slot
  # (S-SCH-01.2), which this seed cannot express.
  @resource = resource
  @slot_start = booking_start(date, time)
end

Given("RPMS will file the next appointment as {int}") do |ien|
  RpmsRpc.client.seed(:scheduling_add_appointment, fileman(@slot_start), { appointment_id: ien, error: "" })
end

When("I book an appointment with:") do |table|
  visit engine_path("/scheduling/appointments/new")
  table.rows_hash.each { |label, value| fill_in label, with: value }
  click_button "Book appointment"
end

Then("RPMS was sent a BSDX booking for patient {int} in {string} on {string} at {string} for {int} minutes") do |dfn, resource, date, time, minutes|
  call = received_rpc_calls("BSDX ADD NEW APPOINTMENT").first
  assert call, "BSDX ADD NEW APPOINTMENT was not called"
  start = booking_start(date, time)
  # START^END^DFN^RESOURCE^LENGTH^NOTE^ACCESS_TYPE^CHART_REQUEST (APPADD^BSDX07)
  assert_equal [ fileman(start), fileman(start + (minutes * 60)), dfn.to_s, resource, minutes.to_s, "", "", "" ],
               call[:params]
end

Then("the page says {string} is booked and RPMS filed appointment {int}") do |name, ien|
  assert page.has_css?("[role=status]", text: "#{name} is booked"), page.text
  assert page.has_content?("RPMS filed it as appointment #{ien}"), page.text
end

Then("the appointment shows on the clinic's schedule and in the patient's appointments") do
  pending("waits on: a clinic schedule read (BSDX CLINIC SCHEDULE in SchedulingGateway is PROVISIONAL, no captured RPC) " \
          "and a live broker; the mock cannot read back what BSDX ADD NEW APPOINTMENT filed")
end

Then("the booking is refused, naming {string}, {string}, {string} and {string}") do |*values|
  assert_equal 422, page.status_code
  assert page.has_css?("[role=alert]", text: "The booking was refused"), page.text
  values.each { |value| assert page.has_css?("[role=alert] li", text: value), page.text }
end

Then("the booking is refused, naming {string}") do |value|
  assert_equal 422, page.status_code
  assert page.has_css?("[role=alert]", text: "The booking was refused"), page.text
  assert page.has_css?("[role=alert] li", text: value), page.text
end

Then("no booking was sent to RPMS") do
  assert_empty received_rpc_calls("BSDX ADD NEW APPOINTMENT")
end

# -- S-SCH-02 cancel ------------------------------------------------------------

Given("the cancellation reasons hold {string} as reason {int}") do |name, ien|
  key = RpmsRpc::DdrFileman.lister_param(file: "409.2", xref: "B").to_s
  RpmsRpc.client.seed(:ddr_lister, key, "[Data]\n#{ien}^#{name}")
end

Given("appointment {int} is booked") do |ien|
  # The mock has no appointment state: "booked" is the precondition that the
  # cancellation reply below succeeds; a live broker refuses a cancelled or
  # checked-in one (S-SCH-02.5, S-SCH-02.6), which this seed cannot express.
  @appointment_ien = ien
end

Given("RPMS will accept the cancellation of appointment {int}") do |ien|
  RpmsRpc.client.seed(:scheduling_cancel_appointment, ien.to_s, { error: "" })
end

When("I cancel appointment {int} with:") do |ien, table|
  visit engine_path("/scheduling/appointments/#{ien}/cancellations/new")
  table.rows_hash.each do |label, value|
    if page.has_select?(label)
      select value, from: label
    else
      fill_in label, with: value
    end
  end
  click_button "Cancel appointment"
end

Then("RPMS was sent a BSDX cancellation of appointment {int} by the patient for reason {int} with remarks {string}") do |ien, reason, remarks|
  call = received_rpc_calls("BSDX CANCEL APPOINTMENT").first
  assert call, "BSDX CANCEL APPOINTMENT was not called"
  # BSDX_APPOINTMENT_IEN^TYPE^CANCELLATION_REASON_IEN^USER_NOTE (APPDEL^BSDX08)
  assert_equal [ ien.to_s, "PC", reason.to_s, remarks ], call[:params]
end

Then("the page says appointment {int} was cancelled on behalf of the patient") do |ien|
  assert page.has_css?("[role=status]", text: "RPMS cancelled appointment #{ien} on behalf of the patient"), page.text
end

Then("the slot is open again and the appointment is marked cancelled with the reason") do
  pending("waits on: a read of the appointment's status on PATIENT (#2.98) and of the clinic's slot; " \
          "the mock cannot read back what BSDX CANCEL APPOINTMENT filed, and no confirmed RPC lists a patient's " \
          "appointments with their BSDX IEN and status")
end

Then("the cancellation is refused, naming {string} and {string}") do |*values|
  assert_equal 422, page.status_code
  assert page.has_css?("[role=alert]", text: "The cancellation was refused"), page.text
  values.each { |value| assert page.has_css?("[role=alert] li", text: value), page.text }
end

Then("the cancellation is refused, naming {string}") do |value|
  assert_equal 422, page.status_code
  assert page.has_css?("[role=alert]", text: "The cancellation was refused"), page.text
  assert page.has_css?("[role=alert] li", text: value), page.text
end

Then("no cancellation was sent to RPMS") do
  assert_empty received_rpc_calls("BSDX CANCEL APPOINTMENT")
end

# -- S-SCH-01.12 keys -------------------------------------------------------------

When("I open the booking form") do
  visit engine_path("/scheduling/appointments/new")
end

When("I open the cancellation form for appointment {int}") do |ien|
  visit engine_path("/scheduling/appointments/#{ien}/cancellations/new")
end

Then("it is refused for want of a scheduling key") do
  assert_equal 403, page.status_code
  assert page.has_content?("SDZSUP, SDZMENU"), page.text
end
