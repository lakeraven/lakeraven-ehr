# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/busa"

# lakeraven-ehr#617: a saved registration edit is an audited action, so it
# leaves one BUSA security audit entry (BPRM 6.0 Core_SetBusaAuditLogQ, BUSA
# LOG SECURITY AUDIT ENTRY) for the patient, with a fixed description that
# holds no PHI. BUSA takes the user from the broker session.
#
# The RPMS change has already happened when the entry is written and cannot be
# undone, so an entry RPMS does not file leaves the edit as saved and is
# recorded locally as a gap. RPMS is stood in for at the gem boundary, as in
# registration_edit_patient_test.rb.
class RegistrationBusaAuditTest < ActionDispatch::IntegrationTest
  DFN = 990_031

  RECORD = {
    dfn: DFN, name: "TESTPATIENT,ALPHA", dob: Date.new(1997, 3, 15), dob_text: "MAR 15,1997",
    name_last: "TESTPATIENT", name_first: "ALPHA", ssn: "666321031", ssn_verification: "Pending Verification",
    sex: { internal: "F", external: "FEMALE" }, marital_status: { internal: "2", external: "MARRIED" },
    hrn: "990031", birth_city: nil, birth_state: nil, employer: nil, employment_status: nil,
    religion: { internal: "1", external: "CATHOLIC" },
    address_line1: "317 DUNEGRASS ST", address_line2: nil, address_line3: nil, city: "ANYWHERE",
    state: { internal: "27", external: "MONTANA" }, zip: "59000", phone_home: "406-555-1031",
    phone_work: nil, phone_other: nil, community: nil
  }.freeze
  HEADER = { name: "TESTPATIENT,ALPHA", dob: Date.new(1997, 3, 15), sex: "F", mrn: "990031" }.freeze
  CONTACT = { dfn: DFN, phone_home: "406-555-1031", phone_work: nil, phone_cell: "406-555-2000", phone_other: nil,
              email: "alpha@example.test" }.freeze
  PICKS = { marital_status: [ { ien: 2, name: "MARRIED" }, { ien: 6, name: "NEVER MARRIED" } ],
            religion: [ { ien: 1, name: "CATHOLIC" } ], state: [ { ien: 27, name: "MONTANA" } ],
            employer: [ { ien: 1, name: "EXAMPLE EMPLOYER" } ] }.freeze
  ENROLLMENT = { enrollment_number: "ZZ1", tribe_ien: 532, tribe_name: "EXAMPLE TRIBE", tribe_quantum: "1/4",
                 indian_blood_quantum: "1/2", classification_ien: 2, classification: "INDIAN/ALASKA NATIVE",
                 eligibility_status: "C", community: "NORTH LANDING" }.freeze
  CLASSIFICATIONS = [ { ien: "2", pieces: [ "INDIAN/ALASKA NATIVE" ] }, { ien: "1", pieces: [ "OTHER" ] } ].freeze

  BUSA_FILED = { success: true, message: "" }.freeze
  # What the form carries that must never reach an audit row.
  PHI = [ "TESTPATIENT", "ALPHA", "666321031", "1997", "MAR 15" ].freeze

  setup { busa_gap_rows.delete_all }
  teardown { busa_gap_rows.delete_all }

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  def stub(receiver, name, &body)
    (@restores ||= []) << StubHelpers.install_singleton_stub(receiver, name, nil)
    receiver.define_singleton_method(name, &body)
  end

  # RPMS as the gem answers. `updates` is what AG was sent, `busa` what BUSA
  # was sent. A BUSA reply that is an exception is raised.
  def with_rpms(*update_replies, busa_reply: BUSA_FILED)
    updates = []
    busa = []
    stub(RpmsRpc::Registration, :address_history) { |_dfn| [] }
    stub(RpmsRpc::Registration, :change_address) do |dfn, moved_on:, **attrs|
      updates << [ dfn, attrs.merge(moved_on: moved_on) ]
      update_replies.shift
    end
    stub(RpmsRpc::Patient, :brief_header) { |_dfn| HEADER }
    stub(RpmsRpc::Patient, :registration_record) { |dfn| dfn.to_i == DFN ? RECORD : nil }
    stub(RpmsRpc::Patient, :contact) { |_dfn| CONTACT }
    stub(RpmsRpc::Registration, :pick_list) { |attribute, **| PICKS.fetch(attribute) }
    stub(RpmsRpc::Tribal, :enrollment) { |_dfn| ENROLLMENT }
    stub(RpmsRpc::Tribal, :tribes) { |**| [] }
    stub(RpmsRpc::DdrFileman, :lister) { |**| { entries: CLASSIFICATIONS, error: false } }
    stub(RpmsRpc::Patient, :update) do |dfn, **attrs|
      updates << [ dfn, attrs ]
      update_replies.shift
    end
    stub(RpmsRpc::Busa, :log_security_audit) do |**pieces|
      busa << pieces
      raise busa_reply if busa_reply.is_a?(Exception)

      busa_reply
    end
    yield updates, busa
  ensure
    @restores&.reverse_each(&:call)
    @restores = nil
  end

  def saved = { success: true, dfn: DFN }

  def demographics(**changes)
    { name: "TESTPATIENT,ALPHA", dob: "1997-03-15", sex: "F", marital_status: "2", religion: "1", birth_city: "",
      birth_state: "", employer: "", employment_status: "", ssn: "" }.merge(changes)
  end

  def address(**changes)
    { address_line1: "317 DUNEGRASS ST", address_line2: "", address_line3: "", city: "ANYWHERE", state: "27",
      zip: "59000", phone_home: "406-555-1031", phone_work: "", phone_other: "", email: "alpha@example.test" }.merge(changes)
  end

  def eligibility(**changes)
    { eligibility_status: "C", classification_ien: "2", tribe_ien: "532", blood_quantum: "1/2", tribe_quantum: "1/4",
      enrollment_number: "ZZ1" }.merge(changes)
  end

  def patient_path = "/lakeraven-ehr/registration/patients/#{DFN}"

  def save_demographics(**changes)
    patch "#{patient_path}/demographics", params: { demographics: demographics(marital_status: "6", **changes) }
  end

  def busa_entry(description)
    { category: "P", action: "E", call: "LAKERAVEN EHR REGISTRATION", description: description, detail: DFN.to_s }
  end

  def busa_gap_rows
    Lakeraven::EHR::AuditEvent.where(entity_type: "Patient", entity_identifier: DFN.to_s)
                              .where("outcome_desc LIKE ?", "BUSA entry not filed:%")
  end

  # The one local row that records a BUSA entry RPMS did not file.
  def assert_busa_gap_recorded(reason_pattern)
    rows = busa_gap_rows.to_a
    assert_equal 1, rows.size, "expected one local audit row for the BUSA entry that was not filed"
    row = rows.first
    assert_equal "security", row.event_type
    assert_equal "U", row.action
    assert_equal "4", row.outcome
    assert_equal "Patient", row.entity_type
    assert_equal DFN.to_s, row.entity_identifier
    reason = row.outcome_desc.delete_prefix("BUSA entry not filed:").strip
    assert reason.present?, "the row must carry the gateway's reason"
    assert_match reason_pattern, reason
    held = row.attributes.values.compact.map(&:to_s).join(" ")
    PHI.each { |phi| refute_includes held, phi, "the audit row must hold no PHI" }
    row
  end

  test "a saved demographics edit files one BUSA entry for the patient, and records no gap" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates, busa|
      save_demographics

      assert_redirected_to patient_path
      assert_equal "Demographics saved.", flash[:notice]
      assert_equal 1, updates.size
      assert_equal [ busa_entry("Registration: demographics edited") ], busa
      assert_equal 0, busa_gap_rows.count
    end
  end

  test "the BUSA entry for demographics holds nothing from the form" do
    sign_in("registration_menu")
    with_rpms(saved) do |_updates, busa|
      save_demographics(name: "TESTPATIENT,ALPHA B", dob: "1997-03-16", ssn: "666321032")

      assert_equal 1, busa.size, "expected one BUSA entry"
      sent = busa.first.values.join(" ")
      (PHI + [ "666321032" ]).each { |phi| refute_includes sent, phi, "the BUSA entry must hold no PHI" }
    end
  end

  test "a saved phone change files one BUSA entry described as an address edit" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates, busa|
      patch "#{patient_path}/address", params: { address: address(phone_work: "406-555-0143") }

      assert_redirected_to patient_path
      assert_equal 1, updates.size
      assert_equal [ busa_entry("Registration: address edited") ], busa
    end
  end

  test "a change of address files one BUSA entry, not one per RPMS call" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates, busa|
      patch "#{patient_path}/address", params: { address: address(city: "Elsewhere", moved_on: "2025-11-01") }

      assert_redirected_to patient_path
      assert_equal 1, updates.size
      assert_equal [ busa_entry("Registration: address edited") ], busa
    end
  end

  test "an address saved without its history is still an edit: one BUSA entry, and the clerk is told both" do
    sign_in("registration_menu")
    partial = { success: false, error: :partial, message: "The address was saved, but the previous address was not kept: refused" }
    with_rpms(partial) do |_updates, busa|
      patch "#{patient_path}/address", params: { address: address(city: "Elsewhere") }

      assert_redirected_to patient_path
      assert_equal partial[:message], flash[:alert]
      assert_equal [ busa_entry("Registration: address edited") ], busa
    end
  end

  test "a saved eligibility edit files one BUSA entry described as an eligibility edit" do
    sign_in("registration_menu")
    with_rpms(saved) do |updates, busa|
      patch "#{patient_path}/eligibility", params: { eligibility: eligibility(blood_quantum: "3/4"), commit: "Save" }

      assert_redirected_to patient_path
      assert_equal 1, updates.size
      assert_equal [ busa_entry("Registration: eligibility edited") ], busa
    end
  end

  # The saved edit at the end is the control: the same stand-in that saw
  # nothing for the three edits that changed nothing in RPMS sees the one
  # that did.
  test "an edit RPMS refused, one whose outcome is unknown and an invalid form file no BUSA entry; the saved one after them does" do
    sign_in("registration_menu")
    refusal = { success: false, error: :agg_invalid, field: :zip, message: "Enter 5 or 9 digit zip code." }
    with_rpms(refusal, nil, saved) do |updates, busa|
      patch "#{patient_path}/address", params: { address: address(zip: "5900") }
      assert_response :unprocessable_content
      assert_equal 1, updates.size, "RPMS must have been asked and refused"
      assert_empty busa, "a refused write is not an edit"

      patch "#{patient_path}/address", params: { address: address(phone_home: "406-555-0101") }
      assert_response :service_unavailable
      assert_equal 2, updates.size, "RPMS must have been asked and not answered"
      assert_empty busa, "a write whose outcome is unknown is not audited as an edit"

      patch "#{patient_path}/address", params: { address: address(phone_work: "123") }
      assert_response :unprocessable_content
      assert_equal 2, updates.size, "an invalid form does not reach RPMS"
      assert_empty busa, "an invalid form is not an edit"

      patch "#{patient_path}/address", params: { address: address(phone_work: "406-555-0143") }
      assert_redirected_to patient_path
      assert_equal 3, updates.size
      assert_equal [ busa_entry("Registration: address edited") ], busa
      assert_equal 0, busa_gap_rows.count
    end
  end

  test "when RPMS refuses the BUSA entry without a message, the edit stands and one local row records the gap" do
    sign_in("registration_menu")
    with_rpms(saved, busa_reply: { success: false, message: "" }) do |updates, busa|
      save_demographics(name: "TESTPATIENT,ALPHA B", dob: "1997-03-16", ssn: "666321032")

      assert_redirected_to patient_path
      assert_equal "Demographics saved.", flash[:notice]
      assert_equal 1, updates.size
      assert_equal 1, busa.size, "BUSA must have been asked"
      row = assert_busa_gap_recorded(/\S/)
      refute_includes row.attributes.values.compact.map(&:to_s).join(" "), "666321032"
    end
  end

  test "when RPMS refuses the BUSA entry with a reason, the local row carries that reason" do
    sign_in("registration_menu")
    with_rpms(saved, busa_reply: { success: false, message: "DUZ is not defined" }) do |_updates, busa|
      save_demographics

      assert_redirected_to patient_path
      assert_equal "Demographics saved.", flash[:notice]
      assert_equal 1, busa.size, "BUSA must have been asked"
      assert_busa_gap_recorded(/DUZ is not defined/)
    end
  end

  test "when RPMS does not answer the BUSA call, the edit stands and one local row records the gap" do
    sign_in("registration_menu")
    with_rpms(saved, busa_reply: nil) do |_updates, busa|
      save_demographics

      assert_redirected_to patient_path
      assert_equal "Demographics saved.", flash[:notice]
      assert_equal 1, busa.size, "BUSA must have been asked"
      assert_busa_gap_recorded(/did not answer/i)
    end
  end

  test "when the BUSA call raises, the edit stands and one local row names the exception class" do
    sign_in("registration_menu")
    with_rpms(saved, busa_reply: RpmsRpc::Client::RpcError.new("broker refused the call")) do |_updates, busa|
      save_demographics

      assert_redirected_to patient_path
      assert_equal "Demographics saved.", flash[:notice]
      assert_equal 1, busa.size, "BUSA must have been asked"
      assert_busa_gap_recorded(/RpmsRpc::Client::RpcError/)
    end
  end

  test "a partially saved address whose BUSA entry is not filed keeps its alert and records the gap" do
    sign_in("registration_menu")
    partial = { success: false, error: :partial, message: "The address was saved, but the previous address was not kept: refused" }
    with_rpms(partial, busa_reply: nil) do |_updates, busa|
      patch "#{patient_path}/address", params: { address: address(city: "Elsewhere") }

      assert_redirected_to patient_path
      assert_equal partial[:message], flash[:alert]
      assert_equal 1, busa.size, "BUSA must have been asked"
      assert_busa_gap_recorded(/did not answer/i)
    end
  end
end
