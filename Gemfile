# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RPMS_RPC_PATH"]
  gem "rpms-rpc", path: ENV["RPMS_RPC_PATH"]
else
  # Pinned to rpms-rpc main 5188b49: Registration.preferred_name and set_preferred_name (rpms-rpc#591), and held_keys asks ORWU NPHASKEY under CIAV VUECENTRIC, so a front-desk user signs on over CIA (rpms-rpc#556, #590). Earlier, f0a255e: Scheduling.edit_appointment and variable_length?, SchedulingSetup.set_clinic_note
  # and set_cancellation_remarks, to keep an appointment's details current (rpms-rpc#586). Earlier, 6f3f852: Scheduling.overbook_allowed (BSDX OVERBOOK), SchedulingSetup.master_overbook?
  # and mark_overbook (OVERBOOK, #44.003 field 9) for overbooking (rpms-rpc#584). Earlier, 9197bf5: PatientProfile reads and files the emergency contact, next of kin,
  # languages and other names through AG's windows (rpms-rpc#580), and Registration.update files blood and
  # tribe quantum and the enrollment number (rpms-rpc#582). Earlier, f306a32: Scheduling.checkout_appointment, cancel_checkout and cancel_checkin, and
  # SchedulingSetup.clinic_stops and clinic_stop (rpms-rpc#579). Earlier, a8da077: Patient.registration_record reads a registered patient through AG's
  # windows, and Patient.update takes name, religion and employer after AG's own checks (rpms-rpc#581).
  # Earlier, b51d455: Patient.brief_header reads CWAD on the caller's option, so an IRIS
  # stack no longer refuses every patient header (rpms-rpc#576). Earlier, f5392af: Scheduling.add_availability
  # and cancel_availability_by_date set a clinic's hours as BSDX access blocks (rpms-rpc#574). Earlier, 24aaef5: PatientSelection.find finds a patient
  # the way VueCentric's patient selection does (rpms-rpc#550). Earlier, 33f4c64: Practitioner.search can list only the holders of a key
  # (rpms-rpc#545). Earlier, 326d167: SchedulingSetup.clinic_rules names a prohibited clinic's
  # privileged users (rpms-rpc#544). Earlier, 6723a7f: SessionPool can refuse at capacity instead of evicting, and
  # its keeper releases a dropped connection (rpms-rpc#542). Earlier, d59fe4a: RpmsRpc.with_client scopes a request to its user's
  # connection, and SessionPool releases and keeps sessions open (rpms-rpc#518, #533).
  # Earlier, 8c136a1: CIA sign-on tells RPMS the application, the workstation
  # and the person's address (rpms-rpc#516). Earlier, 320cea0: SchedulingSetup reads the access types, holidays and a
  # clinic's booking rules (rpms-rpc#509). Earlier, a40dec0: CiaClient#poll keeps a broker session open, and
  # Authentication.timed_read names the user's idle limit (rpms-rpc#508). Earlier, f132143:
  # Scheduling.patient_appointments, one patient's
  # appointments across clinics (BSDX PATIENT APPT DISPLAY; rpms-rpc#505). Earlier, 02444ff:
  # Registration runs AG's own field checks
  # (AGG WINDOW DATA VALIDATION) before it files, and takes no_ssn_reason (rpms-rpc#503,
  # #504: neither SSN nor reason is refused without the check that hangs the broker).
  # Earlier, 3e0c31d: Authentication.option_access, which options the
  # signed-on user may run (ORWU HAS OPTION ACCESS; rpms-rpc#490), and a failed BSDX
  # list read raises instead of reading as empty (rpms-rpc#500). Earlier, 49ec8b5:
  # Scheduling.appointments (ids and state, for
  # cancel and check-in; rpms-rpc#496). Earlier: Scheduling.resources and slot_schedule (the
  # user's resources and rights, each block's slots; rpms-rpc#495). Earlier:
  # Tribal.communities lists COMMUNITY entries
  # with county and state (rpms-rpc#493), for the registration form. Earlier:
  # Patient.lookup binds AGGRPC (AGG LOOKUP
  # PATIENTS is refused under the CIA sign-on context) and a refused global-array
  # RPC raises at once (rpms-rpc#492); Capabilities and UserRoles removed
  # (rpms-rpc#491, the host decides roles). Earlier: CIA sign-on resolves a DUZ
  # (lakeraven-ehr#540), invented RPC names removed (#310/#311), typed errors for
  # a missing RPC (#370), the user class from ORWU USERINFO (#236). A fixed ref
  # rather than branch:main so the pin does not drift mid-merge.
  gem "rpms-rpc", github: "lakeraven/rpms-rpc", ref: "5188b49"
end

gem "puma"
gem "pg"

# The asset pipeline and Tailwind CSS v4 for the dummy app, the same pair the
# SaaS host runs. Engine pages link the host's Tailwind build (tailwind.css);
# without an asset pipeline that link has no route and every page load 404s it.
gem "propshaft"
gem "tailwindcss-rails", "~> 4.4"

# Tests and lint only: the image installs without them (BUNDLE_WITHOUT).
group :development, :test do
  gem "cucumber-rails", require: false
  gem "minitest"
  # Headless Chrome for the live system tests (test/system/live), which sign in
  # against a real RPMS broker and save screenshots as evidence.
  gem "cuprite", require: false
  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end
