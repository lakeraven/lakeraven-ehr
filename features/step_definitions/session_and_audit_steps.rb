# frozen_string_literal: true

require "digest"
require "rpms_rpc/api/busa"

# lakeraven-ehr#617, features/bprm_twin/session_and_audit.feature. RPMS is
# stood in for at the gem boundary, as test/integration/
# registration_edit_patient_test.rb does: the reads the demographics screen
# makes, AG's update, and BUSA LOG SECURITY AUDIT ENTRY, which records what it
# is sent. Synthetic data only.
module SessionAndAuditSteps
  MOUNT = "/lakeraven-ehr"
  PICKS = { marital_status: [ { ien: 2, name: "MARRIED" }, { ien: 6, name: "NEVER MARRIED" } ],
            religion: [ { ien: 1, name: "CATHOLIC" } ], state: [ { ien: 27, name: "MONTANA" } ],
            employer: [ { ien: 1, name: "EXAMPLE EMPLOYER" } ] }.freeze

  def registration_record(dfn)
    { dfn: dfn, name: "TESTPATIENT,ALPHA", dob: Date.new(1997, 3, 15), dob_text: "MAR 15,1997",
      name_last: "TESTPATIENT", name_first: "ALPHA", ssn: "666321031", ssn_verification: "Pending Verification",
      sex: { internal: "F", external: "FEMALE" }, marital_status: { internal: "2", external: "MARRIED" },
      hrn: dfn.to_s, birth_city: nil, birth_state: nil, employer: nil, employment_status: nil,
      religion: { internal: "1", external: "CATHOLIC" },
      address_line1: "317 DUNEGRASS ST", address_line2: nil, address_line3: nil, city: "ANYWHERE",
      state: { internal: "27", external: "MONTANA" }, zip: "59000", phone_home: "406-555-1031",
      phone_work: nil, phone_other: nil, community: nil }
  end

  # The reply of release bcer-9.0-20261119-f67498c-ydb to a patient-detail
  # entry, byte for byte as captured live: rpms-rpc
  # test/fixtures/captured_replies/busa-log.yml, patient_detail/1 (sha256
  # fe4c7411...c7a9). That release files the summary, refuses the detail row
  # and answers 0^ with no message.
  CAPTURED_PATIENT_DETAIL_RETURN = "5\0I00001RESULT^T00250ERROR_MESSAGE\x1E0^\x1E"
  CAPTURED_PATIENT_DETAIL_SHA256 = "fe4c741139e42adb431f89a5b31968d2c32d184bb7ce26f673f4c0fc6090c7a9"

  def local_busa_rows(dfn)
    Lakeraven::EHR::AuditEvent.where(event_type: "security", entity_type: "Patient", entity_identifier: dfn.to_s)
                              .where("outcome_desc LIKE ?", "BUSA entry%")
  end

  # Saved and restored with the scenario's other gateway stubs.
  def stub_rpms(receiver, name, &body)
    @gateway_stubs << StubHelpers.install_singleton_stub(receiver, name, nil)
    receiver.define_singleton_method(name, &body)
  end

  def the_busa_entry
    assert_equal 1, @busa_entries.size, "expected exactly one BUSA security audit entry"
    @busa_entries.first
  end
end

World(SessionAndAuditSteps)

Given("a registration clerk is signed on as RPMS user {int}") do |duz|
  post "#{SessionAndAuditSteps::MOUNT}/test_session",
       duz: duz.to_s, user_type: "user", user_name: "PROFILE,REG", security_keys: "registration_menu"
  assert_includes 200..399, last_response.status, "sign-on failed: #{last_response.status}"
end

Given("RPMS holds registered patient {int}") do |dfn|
  record = registration_record(dfn)
  updates = (@registration_updates = [])
  busa = (@busa_entries = [])
  # What RPMS answers a BUSA entry with. Success unless a later step says so.
  busa_answer = (@busa_answer = { reply: { success: true, message: "" } })
  # The gap row is written outside the scenario's transaction, so it is
  # cleared here and again with the scenario's stubs.
  local_busa_rows(dfn).delete_all
  @gateway_stubs << -> { local_busa_rows(dfn).delete_all }
  stub_rpms(RpmsRpc::Patient, :brief_header) { |_dfn| { name: record[:name], dob: record[:dob], sex: "F", mrn: dfn.to_s } }
  stub_rpms(RpmsRpc::Patient, :registration_record) { |asked| asked.to_i == dfn ? record : nil }
  stub_rpms(RpmsRpc::Patient, :contact) { |_dfn| { dfn: dfn, phone_home: record[:phone_home] } }
  stub_rpms(RpmsRpc::Registration, :pick_list) { |attribute, **| SessionAndAuditSteps::PICKS.fetch(attribute) }
  stub_rpms(RpmsRpc::Patient, :update) do |asked, **attrs|
    updates << [ asked, attrs ]
    { success: true, dfn: asked }
  end
  stub_rpms(RpmsRpc::Busa, :log_security_audit) do |**pieces|
    busa << pieces
    busa_answer[:reply]
  end
end

# The reply is the gem's parse of the captured wire return, so the scenario
# follows what release bcer-9.0-20261119-f67498c-ydb sent, not a hash written to suit the app.
Given("RPMS answers the BUSA entry with the captured reply of bcer-9.0-20261119-f67498c-ydb for a patient-detail row") do
  raw = SessionAndAuditSteps::CAPTURED_PATIENT_DETAIL_RETURN
  assert_equal SessionAndAuditSteps::CAPTURED_PATIENT_DETAIL_SHA256, Digest::SHA256.hexdigest(raw),
               "the reply must be the captured raw_return, byte for byte"
  @busa_answer[:reply] = RpmsRpc::Busa.parse_log_reply(raw)
end

When("the clerk saves a change to the demographics of patient {int}") do |dfn|
  patch "#{SessionAndAuditSteps::MOUNT}/registration/patients/#{dfn}/demographics",
        demographics: { name: "TESTPATIENT,ALPHA", dob: "1997-03-15", sex: "F", marital_status: "6", religion: "1",
                        birth_city: "", birth_state: "", employer: "", employment_status: "", ssn: "" }
  @edited_dfn = dfn
end

When("the clerk saves the demographics of patient {int} without changing anything") do |dfn|
  patch "#{SessionAndAuditSteps::MOUNT}/registration/patients/#{dfn}/demographics",
        demographics: { name: "TESTPATIENT,ALPHA", dob: "1997-03-15", sex: "F", marital_status: "2", religion: "1",
                        birth_city: "", birth_state: "", employer: "", employment_status: "", ssn: "" }
  @edited_dfn = dfn
end

Then("the clerk is returned to patient {int}") do |dfn|
  assert_equal 302, last_response.status, "expected a redirect to the patient page, got #{last_response.status}"
  assert_match %r{/registration/patients/#{dfn}\z}, last_response.headers["Location"].to_s
end

Then("RPMS is asked to change nothing") do
  assert_empty @registration_updates, "nothing changed, so RPMS must not be asked to update"
end

Then("the change is saved") do
  assert_equal 302, last_response.status, "expected a redirect to the patient page, got #{last_response.status}"
  assert_match %r{/registration/patients/#{@edited_dfn}\z}, last_response.headers["Location"].to_s
  assert_equal [ [ @edited_dfn, { marital_status: "6" } ] ], @registration_updates
end

Then("RPMS receives exactly {int} BUSA security audit entry/entries") do |count|
  assert_equal count, @busa_entries.size,
               "expected #{count} BUSA LOG SECURITY AUDIT ENTRY call(s), RPMS received #{@busa_entries.size}"
end

Then("the BUSA entry names patient {int}") do |dfn|
  assert_equal dfn.to_s, the_busa_entry[:detail]
end

Then("the BUSA entry records a patient edit described as {string}") do |description|
  entry = the_busa_entry
  assert_equal "P", entry[:category]
  assert_equal "E", entry[:action]
  assert_equal "LAKERAVEN EHR REGISTRATION", entry[:call]
  assert_equal description, entry[:description]
end

# BUSA takes the user (DUZ) from the broker session the entry is written on.
# The app sends the five pieces and no user of its own.
Then("the BUSA entry carries no user, because RPMS takes the user from the session") do
  assert_equal %i[action call category description detail], the_busa_entry.keys.sort
end

Then("exactly {int} local {string} row names patient {int}") do |count, what, dfn|
  rows = local_busa_rows(dfn).to_a
  assert_equal count, rows.size, "expected #{count} local BUSA row(s) for patient #{dfn}, found #{rows.size}"
  rows.each do |row|
    assert row.outcome_desc.start_with?("#{what}: "), "expected #{what.inspect}, got #{row.outcome_desc.inspect}"
    assert row.outcome_desc.delete_prefix("#{what}: ").strip.present?, "the row must say why"
    assert_equal dfn.to_s, row.entity_identifier
  end
end
