# frozen_string_literal: true

# BPRM twin — PARITY step definition stub.
#
# features/bprm_twin/parity.feature asserts that the same clinical action leaves
# IDENTICAL FileMan state whether driven through lakeraven-ehr (RPCs) or BPRM v4
# (BMW-SQL) — the guarantee that lets lakeraven-ehr stand in for BPRM v4's
# reg/sched. Full design: docs/BPRM_PARITY_PLAN.md (lakeraven-ehr#416).
#
# Two axes:
#   @engine  — lakeraven-ehr on BACKEND=ydb vs BACKEND=iris → responses identical.
#   @path    — lakeraven-ehr RPC write vs BPRM BMW.BSF.SP write → FileMan read-back identical.
#
# These steps are intentionally PENDING until the harness lands (red → green,
# BDD as-we-go). The harness they will use:
#   features/support/backends.rb        — BACKEND=ydb|iris → rpms_rpc connection
#   features/support/bprm_golden.rb     — invoke BMW.BSF.SP on IRIS, capture read-back
#   features/support/fileman_readback.rb— $$GET1^DIQ over the parity field set
#   features/support/normalize.rb       — strip IEN/DFN/DUZ/timestamps before diff
#
# @engine YDB arm is blocked on RPMS Kernel sign-on on YDB (rpms-ops#343); the
# @path golden + IRIS arm can be implemented first.

module BprmParityPending
  def parity_pending!(what)
    pending("BPRM parity: not yet implemented — #{what}")
  end
end
World(BprmParityPending)

# --- Background --------------------------------------------------------------
Given("a clean baseline patient fixture") do
  parity_pending!("reset FileMan fixture to a known-empty reg/sched baseline")
end

Given("the parity oracle reads FileMan back with IEN\\/DFN\\/DUZ\\/timestamps normalized") do
  parity_pending!("normalize.rb: canonicalize non-deterministic fields before diff")
end

# --- Engine parity (YDB vs IRIS) ---------------------------------------------
When("I register patient {string} born {string} sex {string} on backend {string}") do |_name, _dob, _sex, _backend|
  parity_pending!("POST /patients on the named rpms_rpc backend (backends.rb)")
end

Then("the HTTP response is recorded for {string}") do |_backend|
  parity_pending!("capture normalized HTTP response keyed by backend")
end

Then("the FileMan read-back of #2\\/#9000001 is recorded for {string}") do |_backend|
  parity_pending!("fileman_readback.rb: read #2 + #9000001 for the new DFN")
end

Given("a registration was run on backend {string}") do |_backend|
  parity_pending!("run the reference registration on the named backend")
end

Given("the same registration was run on backend {string}") do |_backend|
  parity_pending!("run the identical registration on the other backend")
end

Then("the two HTTP responses are identical after normalization") do
  parity_pending!("assert normalized(ydb.response) == normalized(iris.response)")
end

Then("the two FileMan read-backs of #2\\/#9000001 are identical after normalization") do
  parity_pending!("assert normalized(ydb.readback) == normalized(iris.readback)")
end

# --- Path parity (lakeraven-ehr RPC vs BPRM BMW-SQL) -------------------------
When("I register patient {string} born {string} sex {string} via lakeraven-ehr") do |_name, _dob, _sex|
  parity_pending!("POST /patients -> BHDPTRPC/AG registration RPC")
end

When("BPRM registers the same patient via BMW.BSF.SP against IRIS") do
  parity_pending!("bprm_golden.rb: invoke the registration SqlProc, capture read-back")
end

Then("the FileMan read-back of #2\\/#9000001 matches the BPRM golden") do
  parity_pending!("assert normalized(ehr.readback) == bprm_golden(#2/#9000001)")
end

When("I book patient {string} into clinic {int} at {string} via lakeraven-ehr") do |_name, _ien, _at|
  parity_pending!("POST /clinics/:ien/appointments -> BSDX ADD NEW APPOINTMENT")
end

When("BPRM books the same slot via BMW.BSF.SP \\(BSDX_APPOINTMENT\\) against IRIS") do
  parity_pending!("bprm_golden.rb: BSDX_APPOINTMENT SqlProc, capture read-back")
end

Then("the FileMan read-back of #409.* \\/ BSDX appointment matches the BPRM golden") do
  parity_pending!("assert normalized(ehr.readback) == bprm_golden(#409.*/BSDX)")
end

When("I admit patient {string} to ward {int} at {string} via lakeraven-ehr") do |_name, _ien, _at|
  parity_pending!("POST /patients/:dfn/movements -> DGPMV* admit")
end

When("BPRM admits the same patient via BMW.BSF.SP against IRIS") do
  parity_pending!("bprm_golden.rb: admission SqlProc (raw ^DGPM), capture read-back")
end

Then("the FileMan read-back of #405 matches the BPRM golden") do
  parity_pending!("assert normalized(ehr.readback) == bprm_golden(#405); flag BPRM xref bypass")
end

# --- Error parity ------------------------------------------------------------
When("I register a patient with no date of birth via lakeraven-ehr") do
  parity_pending!("POST /patients missing DOB -> expect validated rejection")
end

Then("both paths reject the write") do
  parity_pending!("assert both lakeraven-ehr and BPRM SqlProc reject the write")
end

Then("no #2\\/#9000001 record is created by either path") do
  parity_pending!("assert FileMan has no new #2/#9000001 entry from either path")
end
