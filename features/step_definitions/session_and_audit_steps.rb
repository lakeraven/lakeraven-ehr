# frozen_string_literal: true

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
    { success: true, message: "" }
  end
end

When("the clerk saves a change to the demographics of patient {int}") do |dfn|
  patch "#{SessionAndAuditSteps::MOUNT}/registration/patients/#{dfn}/demographics",
        demographics: { name: "TESTPATIENT,ALPHA", dob: "1997-03-15", sex: "F", marital_status: "6", religion: "1",
                        birth_city: "", birth_state: "", employer: "", employment_status: "", ssn: "" }
  @edited_dfn = dfn
end

Then("the change is saved") do
  assert_equal 302, last_response.status, "expected a redirect to the patient page, got #{last_response.status}"
  assert_match %r{/registration/patients/#{@edited_dfn}\z}, last_response.headers["Location"].to_s
  assert_equal [ [ @edited_dfn, { marital_status: "6" } ] ], @registration_updates
end

Then("RPMS receives exactly {int} BUSA security audit entry") do |count|
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
Then("the BUSA entry leaves the user to RPMS, which records the signed-on user") do
  assert_equal %i[action call category description detail], the_busa_entry.keys.sort
end
