# frozen_string_literal: true

# Stands in for RpmsRpc::PatientProfile at the gem boundary, for the
# registration sections' tests (rpms-ux S-REG-08, S-REG-10, S-REG-12).
module PatientProfileStubs
  DFN = 990_008
  HEADER = { name: "HOTEL,DREW", dob: Date.new(1982, 11, 8), sex: "M", mrn: "990008" }.freeze
  ENGLISH = 144
  SPANISH = 531
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze

  CONTACT = { name: "DOE,JANE", relationship: { ien: 22, name: "SPOUSE" }, other_relationship: "", address_line1: "1 MAIN ST",
              address_line2: "", address_line3: "", city: "ANYTOWN", state: { ien: 48, name: "WASHINGTON" }, zip: "12345",
              phone: "555-555-0100", phone_work: "" }.freeze

  def sign_in(keys = "registration_menu")
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  # Stands in for RpmsRpc::PatientProfile: each name answers from its lambda,
  # and every call is recorded as [name, args, kwargs].
  def with_profile(**answers)
    calls = []
    profile = RpmsRpc::PatientProfile
    defaults = { contacts: ->(*) { { emergency: CONTACT, next_of_kin: {} } }, relationships: ->(*) { [] }, states: ->(*) { [] },
                 language_lookup: ->(text) { text == "ENGLISH" ? [ { ien: ENGLISH, name: "ENGLISH" } ] : [] },
                 languages: ->(*) { {} }, aliases: ->(*) { [] } }
    restores = defaults.merge(answers).map do |name, answer|
      restore = StubHelpers.send(:singleton_method_restore, profile, name)
      profile.define_singleton_method(name) do |*args, **kwargs|
        calls << [ name, args, kwargs ]
        kwargs.empty? ? answer.call(*args) : answer.call(*args, **kwargs)
      end
      restore
    end
    StubHelpers.with_stub(RpmsRpc::Patient, :brief_header, HEADER) { yield calls }
  ensure
    restores&.each(&:call)
  end

  def sent(calls, name) = calls.select { |call| call.first == name }
end
