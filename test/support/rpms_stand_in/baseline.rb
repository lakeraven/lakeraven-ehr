# frozen_string_literal: true

module RpmsStandIn
  # What every test starts from: three synthetic patients, two practitioners,
  # one facility and clinic, the VFC eligibility codes, one patient's vitals,
  # and four users who can sign on. Installed before every example
  # (GlobalStoreIsolation), so an answer a test adds cannot leak into the next.
  #
  # Each answer is what the rpms-rpc method the engine calls returns: typed
  # facts, not replies. Synthetic values throughout.
  module Baseline
    PATIENTS = {
      1 => { name: "Anderson,Alice", sex: "F", dob: Date.new(1980, 5, 15), ssn: "111-11-1111", age: 45 },
      2 => { name: "MOUSE,MICKEY M", sex: "M", dob: Date.new(2010, 2, 14), ssn: "000009999", age: 16 },
      3 => { name: "DOE,JANE", sex: "F", dob: Date.new(1990, 12, 25), ssn: "555667777", age: 35 }
    }.freeze

    # RpmsRpc::Patient.find_by_ssn answers from the SSN index, which holds the
    # SSN without punctuation and carries no date of birth.
    SSN_INDEX = { "111111111" => { dfn: 1, name: "Anderson,Alice", dob: nil, ssn: "111111111" } }.freeze

    PRACTITIONERS = [
      { ien: 101, name: "MARTINEZ,SARAH", title: "MD" },
      { ien: 102, name: "CHEN,JAMES", title: "DO" }
    ].freeze

    # RpmsRpc::Practitioner.find reads the session user (ORWU USERINFO), so it
    # answers for one IEN and nil for every other.
    SESSION_PRACTITIONER = { duz: 101, ien: 101, name: "MARTINEZ,SARAH", user_class: 3, usrcls: "3", timed_read: nil,
                             kernel_domain: "DEMO.IHS.GOV", site_ien: 8904 }.freeze

    ORGANIZATION = { ien: 1, name: "Example Health Center", station_number: "463", address: "500 Example Way",
                     city: "Anchorage", state: "ALASKA", zip_code: "99508", phone: nil }.freeze
    LOCATION = { ien: 1, name: "Primary Care Clinic", abbreviation: "PCC", type: "CLINIC",
                 division: "Example Health Center" }.freeze

    VFC_CODES = [
      { code: "V01", label: "Not VFC eligible" },
      { code: "V02", label: "VFC eligible - Medicaid" },
      { code: "V03", label: "VFC eligible - Uninsured" },
      { code: "V04", label: "Am Indian/AK Native" },
      { code: "V05", label: "VFC eligible - FQHC" },
      { code: "V06", label: "VFC eligible - State specific" },
      { code: "V07", label: "VFC eligible - Local specific" }
    ].freeze

    # DFN 1's vitals, as RpmsRpc::Vital.for_patient returns them on RPMS: IHS
    # MEASUREMENT TYPE codes, the recorded text in display, no units.
    VITALS_TAKEN = Time.new(2026, 9, 11, 21, 34)
    VITALS = [
      { measurement_ien: 5,  type: "TMP", value: "98",     recorded_date: VITALS_TAKEN, display: "98 F", metric_display: "(36.7 C)", qualifiers: nil },
      { measurement_ien: 6,  type: "PU",  value: "50",     recorded_date: VITALS_TAKEN, display: "50", metric_display: nil, qualifiers: nil },
      { measurement_ien: 7,  type: "RS",  value: "20",     recorded_date: VITALS_TAKEN, display: "20", metric_display: nil, qualifiers: nil },
      { measurement_ien: 8,  type: "BP",  value: "117/81", recorded_date: VITALS_TAKEN, display: "117/81", metric_display: nil, qualifiers: nil },
      { measurement_ien: 10, type: "PA",  value: "0",      recorded_date: VITALS_TAKEN, display: "0", metric_display: nil, qualifiers: nil },
      { measurement_ien: 9,  type: "O2",  value: "98",     recorded_date: VITALS_TAKEN, display: "98", metric_display: nil, qualifiers: nil }
    ].freeze

    # The DFNs the suite opens: these three and the demo panel's (2-7).
    NOT_SENSITIVE_DFNS = (1..7).to_a.freeze

    module_function

    def call(rpms)
      patients(rpms)
      rpms.answer(RpmsRpc::Practitioner, :search) do |text = "", **|
        PRACTITIONERS.select { |row| row[:name].upcase.start_with?(text.to_s.upcase) }.map(&:dup)
      end
      rpms.answer(RpmsRpc::Practitioner, :find, 101, with: SESSION_PRACTITIONER.dup)
      rpms.answer(RpmsRpc::Organization, :find, 1, with: ORGANIZATION.dup)
      rpms.answer(RpmsRpc::Location, :find, 1, with: LOCATION.dup)
      rpms.answer(RpmsRpc::Eligibility, :codes, with: VFC_CODES.map(&:dup))
      rpms.answer(RpmsRpc::Eligibility, :for_patient, 1, with: { code: "V04", label: "Am Indian/AK Native" })
      rpms.answer(RpmsRpc::Vital, :for_patient, 1, with: VITALS.map(&:dup))
      rpms.not_sensitive(*NOT_SENSITIVE_DFNS)
      users(rpms)
    end

    def patients(rpms)
      PATIENTS.each { |dfn, row| rpms.answer(RpmsRpc::Patient, :find, dfn, with: row.merge(dfn: dfn)) }
      rpms.answer(RpmsRpc::Patient, :find_by_ssn) { |ssn| SSN_INDEX[ssn.to_s.delete("^0-9")]&.dup }
      # One page of the name index, whatever the start text: the gateway does
      # the filtering, so a search test exercises it.
      rpms.answer(RpmsRpc::Patient, :search) { |*| PATIENTS.map { |dfn, row| { dfn: dfn, name: row[:name] } } }
    end

    # Everyone RPMS signs on over CIA holds CIAV VUECENTRIC, the context the
    # sign-on binds to. CLERK,TEST (303) is the user without it, and without
    # a key.
    def users(rpms)
      rpms.user(301, access: "testprovider", verify: "test123", name: "PROVIDER,TEST", role: :provider, options: [ "CIAV VUECENTRIC" ])
      rpms.user(302, access: "testnurse", verify: "test123", name: "NURSE,TEST", role: :nurse, options: [ "CIAV VUECENTRIC" ])
      rpms.user(303, access: "testclerk", verify: "test123", name: "CLERK,TEST", role: :clerk)
      rpms.user(304, access: "lindarodriguez", verify: "test123", name: "RODRIGUEZ,LINDA", role: :user,
                     keys: %w[BMCZSUPERVISOR ORELSE], options: [ "CIAV VUECENTRIC" ])
    end
  end

  class << self
    # A fresh stand-in holding the baseline every test starts from.
    def install_baseline!
      install! { |rpms| Baseline.call(rpms) }
    end
  end
end
