# frozen_string_literal: true

# BPRM twin — step definition stub.
#
# The features/bprm_twin/*.feature files are the executable spec ("digital
# twin") for RPMS BPRM registration + scheduling, re-grounded on the VistA RPC
# broker (rpms_rpc) instead of BPRM's IRIS/BMW-SQL tier. See
# docs/BPRM_REG_SCHED_TWIN.md for the scenario -> HTTP -> RPC/FileMan mapping
# and the audit-gap ("sql-mutate -> reimpl") flags.
#
# These steps are intentionally PENDING: the factory implements the gateways
# (registration via BHDPTRPC/AG, scheduling via BSDX ADD/CANCEL/CHECKIN/NOSHOW
# APPOINTMENT -> BSDAPI, ADT via DGPMV*) and turns each step green scenario by
# scenario (red -> green, BDD as-we-go). Until then every step pends so the
# suite is runnable and the spec is visible in cucumber output.
#
# Tag @bprm_twin selects the whole twin; sub-tags: @registration @scheduling
# @adt @eligibility @lookup @admin.

module BprmTwinPending
  def bprm_twin_pending!(rpc_hint)
    pending("BPRM twin: not yet implemented — maps to #{rpc_hint}")
  end
end
World(BprmTwinPending)

# --- Registration (BHDPTRPC REGISTER / AG / ^DPT) ------------------------------
Given("I am authenticated as a registration clerk at service area {string}") do |_area|
  bprm_twin_pending!("session auth + service-area context")
end

When("I submit a registration with:") do |_table|
  bprm_twin_pending!("POST /patients -> BHDPTRPC REGISTER -> AgPatientRegisterEvent (sql-mutate->reimpl)")
end

When("I update patient {int} with:") do |_dfn, _table|
  bprm_twin_pending!("PATCH /patients/:dfn -> BHDPTRPC/AG -> ^DIE on ^DPT (AgPatientUpdateEvent, sql-mutate->reimpl)")
end

# --- Lookup (AgSearchPatient / AgGetPatientFaceSheet, read) --------------------
When("I search patients for {string}") do |_q|
  bprm_twin_pending!("GET /patients?q= -> AgSearchPatient/AgGetPatientSearchResult (read)")
end

When("I request the face sheet for patient {int}") do |_dfn|
  bprm_twin_pending!("GET /patients/:dfn/face_sheet -> AgGetPatientFaceSheet + AgGetPatientErrorsAndWarnings (read)")
end

# --- Eligibility / insurance (BsdGetPatientInsurances / AgSetPatientInsuranceDelete) ---
When("I delete insurance {int} for patient {int}") do |_ins, _dfn|
  bprm_twin_pending!("DELETE /patients/:dfn/insurances/:id -> AgSetPatientInsuranceDelete 7-table cascade (sql-mutate->reimpl)")
end

# --- Scheduling writes (BSDX ADD/CANCEL/CHECKIN/NOSHOW -> BSDAPI) ---------------
When("I book patient {int} into clinic {int} at {string} for {int} minutes") do |_dfn, _clinic, _time, _len|
  bprm_twin_pending!("POST /clinics/:ien/appointments -> BSDX ADD APPOINTMENT -> $$ADD^BSDAPI (BsdSetPatientAppointment, sql-mutate->reimpl)")
end

When("I cancel appointment {int} as {string} with reason {string}") do |_appt, _type, _reason|
  bprm_twin_pending!("POST /appointments/:id/cancel -> BSDX CANCEL APPOINTMENT -> $$CANCEL^BSDAPI (BsdSetPatientAppointmentCancel, sql-mutate->reimpl)")
end

When("I check in appointment {int}") do |_appt|
  bprm_twin_pending!("POST /appointments/:id/check_in -> BSDX CHECKIN APPOINTMENT -> BSDAPI (BsdSetPatientAppointmentCheckIn, sql-mutate->reimpl)")
end

When("I mark appointment {int} as no-show") do |_appt|
  bprm_twin_pending!("POST /appointments/:id/no_show -> BSDX NOSHOW APPOINTMENT -> BSDAPI (fm-write)")
end

# --- Scheduling reads (BMX query over ^SC / BSDX APPOINTMENT) -------------------
When("I request the schedule for clinic {int} on {string}") do |_clinic, _date|
  bprm_twin_pending!("GET /clinics/:ien/schedule -> BsdReportClinicSchedule (read)")
end

When("I request availability for clinic {int} on {string}") do |_clinic, _date|
  bprm_twin_pending!("GET /clinics/:ien/availability -> BsdGetSchedulingAvailableSlots (read)")
end

# --- ADT movements (DGPMV* / ^DGPM #405) ---------------------------------------
When("I admit patient {int} to ward {int} at {string} under provider {string}") do |_dfn, _ward, _time, _prov|
  bprm_twin_pending!("POST /patients/:dfn/movements -> DGPMV* on ^DGPM (BdgSetPatientAdmission, sql-mutate->reimpl)")
end

# NOTE: the remaining Given/When/Then steps referenced by the .feature files are
# deliberately left undefined; cucumber reports them as undefined (snippets),
# which — together with the pending steps above — documents the full surface the
# factory must implement. Fill these in as each gateway lands.
