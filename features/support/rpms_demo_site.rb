# frozen_string_literal: true

# The demo site of the pinned RPMS build, as the build answers for it.
#
# Every fact here was read from a fresh container of the pinned image through
# the rpms-rpc API the engine uses. On a mock run it is seeded into the mock,
# so the mock says what RPMS says. On a live run (LIVE_RPMS=1) it is checked
# against RPMS before the first scenario, and the run aborts on any
# difference: the fake cannot drift from the backend it stands in for.
#
# Values are verbatim, including RPMS's own quirks (trailing spaces in problem
# narratives, mixed-case ORWU NEWPERS names). Change a value only after
# reading it from the pinned build.
module RpmsDemoSite
  BUILD = "rpms-ydb e9b78c8 (bcer-9.0, rpms-ops demo site seed)"

  # ORWPT SELECT / ORWPT ID INFO / ORWPT FULLSSN, by DFN.
  PATIENTS = {
    4 => { name: "DEMO,PATIENT ONE", sex: "F", dob: Date.new(2001, 1, 1), ssn: "666010101" },
    990001 => { name: "ALPHA,CASEY", sex: "F", dob: Date.new(1952, 5, 26), ssn: "666021001" },
    990027 => { name: "ANCHOR,JAMIE", sex: "F", dob: Date.new(1962, 6, 11), ssn: "666281027" },
    990051 => { name: "ALPHA,AVERY", sex: "F", dob: Date.new(1954, 5, 14), ssn: "666521051" }
  }.freeze

  # ORQQVI VITALS. On RPMS (DUZ("AG")="I") VITAL^ORQQVI answers from
  # MSR^ORQQVI, which reads V MEASUREMENT and names each type by its IHS
  # MEASUREMENT TYPE (#9999999.07) code: TMP, PU, RS, BP, O2, PA -- not
  # VistA's T, P, R, POX.
  VITALS = {
    4 => [
      { measurement_ien: 5, type: "TMP", value: "98", recorded_date: Time.new(2026, 9, 11, 21, 34) },
      { measurement_ien: 6, type: "PU", value: "50", recorded_date: Time.new(2026, 9, 11, 21, 34) },
      { measurement_ien: 7, type: "RS", value: "20", recorded_date: Time.new(2026, 9, 11, 21, 34) },
      { measurement_ien: 8, type: "BP", value: "117/81", recorded_date: Time.new(2026, 9, 11, 21, 34) },
      { measurement_ien: 10, type: "PA", value: "0", recorded_date: Time.new(2026, 9, 11, 21, 34) },
      { measurement_ien: 9, type: "O2", value: "98", recorded_date: Time.new(2026, 9, 11, 21, 34) }
    ]
  }.freeze

  # ORQQAL LIST.
  ALLERGIES = {
    4 => [ { ien: "2", allergen: "BEE POLLEN" } ]
  }.freeze

  # ORQQPL LIST. Narratives carry RPMS's trailing space.
  PROBLEMS = {
    4 => [
      { ien: "4", description: "Type 2 diabetes mellitus ", status: "A" },
      { ien: "3", description: "Acute bronchitis ", status: "E" },
      { ien: "5", description: "Acute urinary tract infection ", status: "E" },
      { ien: "6", description: "Coronary atherosclerosis ", status: "E" }
    ]
  }.freeze

  # ORWU NEWPERS: a page of the NEW PERSON name index, in index order.
  PROVIDERS = [
    { ien: "4", name: "Manager,System" },
    { ien: "204", name: "Profile,Ma" },
    { ien: "206", name: "Profile,Md" },
    { ien: "207", name: "Profile,Reg" },
    { ien: "205", name: "Profile,Rn" },
    { ien: "208", name: "Profile,Sched" },
    { ien: "200", name: "Provider,Test" }
  ].freeze

  # BGOVIMM2 GETELIG (active rows of BI TABLE ELIGIBILITY CODES) and
  # BGOVIMM GETVFC, by DFN (IHS-site flag ^ age ^ default label).
  VFC_CODES = [
    { ien: "1", code: "999", label: "Unknown" },
    { ien: "2", code: "V01", label: "Not Eligible" },
    { ien: "3", code: "V02", label: "Medicaid" },
    { ien: "4", code: "V03", label: "Uninsured" },
    { ien: "5", code: "V04", label: "Am Indian/AK Native" },
    { ien: "6", code: "V05", label: "Underinsured Fed Qualified" },
    { ien: "7", code: "V06", label: "State-specific Elig" },
    { ien: "8", code: "V07", label: "Local-specific Elig" }
  ].freeze
  VFC_DEFAULTS = {
    4 => { ihs_site: "Y", age: "25", default_label: "Am Indian/AK Native" }
  }.freeze

  # The demo site's sign-on personas (rpms-ops SEEDPERS; the pairs are
  # published with the seed). user_type is what the engine resolves from
  # ORWU USERINFO's USRCLS: provider 3, nurse 2, clerk 1, else user.
  PERSONAS = {
    "PMD123" => { verify: "PMD123!!", duz: "206", name: "PROFILE,MD", user_type: "provider" },
    "PRN123" => { verify: "PRN123!!", duz: "205", name: "PROFILE,RN", user_type: "nurse" },
    "PMA123" => { verify: "PMA123!!", duz: "204", name: "PROFILE,MA", user_type: "clerk" },
    "PREG123" => { verify: "PREG123!!", duz: "207", name: "PROFILE,REG", user_type: "user" },
    "PSCH123" => { verify: "PSCH123!!", duz: "208", name: "PROFILE,SCHED", user_type: "user" }
  }.freeze

  module_function

  def seed!(mock)
    PATIENTS.each do |dfn, p|
      mock.seed(:patient_select, dfn.to_s, p)
      mock.seed(:patient_id_info, dfn.to_s, p.slice(:ssn, :dob, :sex, :name))
      mock.seed(:patient_ssn, p[:ssn], p.slice(:name, :dob, :ssn).merge(dfn: dfn))
    end
    # ORWPT LIST ALL answers a page of the name index whatever the start text
    # (rpms-rpc #352); the gateway does the prefix filtering.
    mock.seed_collection(:patient_list,
      PATIENTS.sort_by { |_, p| p[:name] }.map { |dfn, p| { dfn: dfn, name: p[:name] } })
    VITALS.each { |dfn, rows| mock.seed_keyed_collection(:vitals, dfn.to_s, rows) }
    ALLERGIES.each { |dfn, rows| mock.seed_keyed_collection(:allergy_list, dfn.to_s, rows) }
    PROBLEMS.each { |dfn, rows| mock.seed_keyed_collection(:problem_list, dfn.to_s, rows) }
    mock.seed_collection(:practitioner_list, PROVIDERS)
    mock.seed_collection(:vfc_eligibility_codes, VFC_CODES)
    VFC_DEFAULTS.each { |dfn, row| mock.seed(:vfc_default, dfn.to_s, row) }
    PERSONAS.each do |access, p|
      mock.seed_user(p[:duz], credentials: "#{access};#{p[:verify]}", name: p[:name], role: p[:user_type].to_sym)
    end
  end

  # Every difference between this file and what the backend answers, as
  # "<what>: expected <x>, got <y>" lines. Empty means they agree.
  def differences
    diffs = []
    check = ->(what, expected, actual) { diffs << "#{what}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual }

    PATIENTS.each do |dfn, p|
      found = RpmsRpc::Patient.find(dfn)
      check.call("patient #{dfn}", p, found&.slice(*p.keys))
      check.call("patient by SSN #{p[:ssn]}", dfn, RpmsRpc::Patient.find_by_ssn(p[:ssn])&.dig(:dfn))
    end
    VITALS.each do |dfn, rows|
      check.call("vitals #{dfn}", rows, project(RpmsRpc::Vital.for_patient(dfn), rows))
    end
    ALLERGIES.each do |dfn, rows|
      check.call("allergies #{dfn}", rows, project(RpmsRpc::Allergy.for_patient(dfn), rows))
    end
    PROBLEMS.each do |dfn, rows|
      check.call("problems #{dfn}", rows, project(RpmsRpc::Problem.for_patient(dfn), rows))
    end
    check.call("providers", PROVIDERS, project(RpmsRpc::Practitioner.search(""), PROVIDERS))
    check.call("VFC codes", VFC_CODES.map { |r| r.slice(:code, :label) }, RpmsRpc::Eligibility.codes)
    VFC_DEFAULTS.each do |dfn, row|
      expected = VFC_CODES.find { |c| c[:label] == row[:default_label] }&.slice(:code, :label)
      check.call("VFC eligibility #{dfn}", expected, RpmsRpc::Eligibility.for_patient(dfn))
    end
    PERSONAS.each do |access, p|
      result = Lakeraven::EHR::AuthenticationService.new.authenticate(access_code: access, verify_code: p[:verify])
      check.call("sign-on #{access}", p.except(:verify), result.success? ? result.value.slice(:duz, :name, :user_type) : result.error)
    end
    diffs
  end

  # The backend's rows cut down to the keys this file states.
  def project(actual, expected_rows)
    keys = expected_rows.flat_map(&:keys).uniq
    Array(actual).map { |row| row.slice(*keys) }
  end
end

if LIVE_RPMS
  diffs = RpmsDemoSite.differences
  abort(<<~MSG) unless diffs.empty?
    LIVE_RPMS=1: RPMS disagrees with features/support/rpms_demo_site.rb (#{RpmsDemoSite::BUILD}).
    Fix the file from the pinned build, or pin the build the file was read from:
      #{diffs.join("\n  ")}
  MSG
  LiveRpmsSession.sign_on!
  warn "[live] RPMS agrees with the demo site fixture (#{RpmsDemoSite::BUILD})"
end
