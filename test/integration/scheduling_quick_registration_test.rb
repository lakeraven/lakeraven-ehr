# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-05: a scheduler booking a caller who is not on file registers
# the minimum, then books, without losing the booking. RPMS is stood in for at
# the gem boundary with what Patient.register answered live on 7c3119b.
class SchedulingQuickRegistrationTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 5, name: "LOOK ONLY CLINIC", inactive: false, time_scale: 15, hospital_location_id: 8,
      view: true, overbook: false, modify_schedule: false, modify_appointments: false }
  ].freeze
  HEADERS = {
    3 => { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", mrn: "1001" },
    990_070 => { name: "CALLER,NEW", dob: Date.new(1990, 5, 1), sex: "F", mrn: "T00003" }
  }.freeze
  ENTRY = { name: "caller,new", sex: "F", dob: "1990-05-01", ssn: "", no_ssn_reason: "N", chart_number: "" }.freeze
  CLINIC = "/lakeraven-ehr/scheduling/clinics/2"
  BOOKING = { start: "2026-10-28T09:00", length: "15" }.freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  # Stands in for scheduling and Patient.register; replies are consumed in order.
  def with_rpms(*replies)
    calls = []
    stubs = {
      RpmsRpc::Scheduling.singleton_class => { resources: ->(*) { RESOURCES } },
      RpmsRpc::Patient.singleton_class => {
        search: ->(_text) { [] },
        brief_header: ->(dfn) { HEADERS[dfn.to_i] },
        register: ->(attrs) { calls << attrs; replies.shift }
      }
    }.merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield calls
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def token
    css_select("#quick-registration-form input[name='submission_id']").first["value"]
  end

  def submit(entry = ENTRY)
    get "#{CLINIC}/registrations/new", params: BOOKING
    post "#{CLINIC}/registrations", params: BOOKING.merge(submission_id: token, registration: entry)
  end

  test "S-REG-05.6 without SDZREGMENU a scheduler who finds no match is not offered to register the caller" do
    sign_in("scheduling_user")
    with_rpms do
      get "#{CLINIC}/appointments/new", params: BOOKING.merge(q: "NOBODY")
      assert_response :ok
      assert_select "#quick-register-link", count: 0

      get "#{CLINIC}/registrations/new", params: BOOKING
      assert_response :forbidden
    end
  end

  test "S-REG-05.6 with SDZREGMENU, a search with no match offers to register the caller, keeping the booking" do
    sign_in(%w[scheduling_user scheduling_registration])
    with_rpms do
      get "#{CLINIC}/appointments/new", params: BOOKING.merge(q: "NOBODY")

      assert_select "#quick-register-link[href=?]", "#{CLINIC}/registrations/new?length=15&start=2026-10-28T09%3A00"
    end
  end

  test "S-REG-05.1 the caller is registered with a temporary chart number, and the booking resumes with them chosen" do
    sign_in(%w[scheduling_user scheduling_registration])
    with_rpms({ success: true, dfn: 990_070, created: true, hrn: "T00003" }) do |calls|
      submit

      assert_equal [ { name: "CALLER,NEW", sex: "F", dob: Date.new(1990, 5, 1), ssn: "", no_ssn_reason: "N", hrn_source: :temporary } ], calls
      assert_redirected_to "#{CLINIC}/appointments/new?booking%5Bpatient_dfn%5D=990070&length=15&start=2026-10-28T09%3A00"
      follow_redirect!
      assert_select "#quick-registered", text: /Registered CALLER,NEW\.\s+Chart number T00003\./
      assert_select "#booking-form input[name='booking[patient_dfn]'][value='990070']"
      assert_select "#booking-form input[name='booking[start]'][value='2026-10-28T09:00']"
      assert_select "#booking-form", text: /Patient chosen: CALLER,NEW, chart number T00003\./
    end
  end

  test "S-REG-05.2 a chart number the caller was given is sent instead of asking for one" do
    sign_in(%w[scheduling_user scheduling_registration])
    with_rpms({ success: true, dfn: 990_070, created: true, hrn: "123456" }) do |calls|
      submit(ENTRY.merge(chart_number: "123456"))

      assert_equal :given, calls.first[:hrn_source]
      assert_equal "123456", calls.first[:hrn]
      assert_response :redirect
    end
  end

  test "S-REG-05.3 a caller already on file is shown as a possible match to book instead, and nothing is filed" do
    sign_in(%w[scheduling_user scheduling_registration])
    with_rpms({ success: false, error: :duplicate_identity, candidate_dfns: [ 3 ], message: "" }) do |calls|
      submit(ENTRY.merge(name: "MOUSE,MICKEY M"))

      assert_response :conflict
      assert_equal 1, calls.size
      assert_select "#possible-matches tr[data-dfn='3'] a[data-book='3'][href=?]",
                    "#{CLINIC}/appointments/new?booking%5Bpatient_dfn%5D=3&length=15&start=2026-10-28T09%3A00"
    end
  end

  test "S-REG-05.4 and 05.5 RPMS's refusal is shown in its words, and the form stays filled in" do
    sign_in(%w[scheduling_user scheduling_registration])
    refusal = { success: false, error: :agg_invalid, field: "AGGPTHRN", message: "HRN 123456 is already assigned to patient CALLER,OTHER" }
    with_rpms(refusal) do
      submit(ENTRY.merge(chart_number: "123456"))

      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /HRN 123456 is already assigned to patient CALLER,OTHER/
      assert_select "#registration_chart_number[value='123456']"
    end
  end

  test "a chart number that is not a number, and a form sent twice, are refused before RPMS is asked" do
    sign_in(%w[scheduling_user scheduling_registration])
    with_rpms({ success: true, dfn: 990_070, created: true, hrn: "T00003" }) do |calls|
      submit(ENTRY.merge(chart_number: "T00001"))
      assert_response :unprocessable_content
      assert_select "#registration-errors", text: /Chart number must be up to six digits/

      get "#{CLINIC}/registrations/new", params: BOOKING
      used = token
      post "#{CLINIC}/registrations", params: BOOKING.merge(submission_id: used, registration: ENTRY)
      post "#{CLINIC}/registrations", params: BOOKING.merge(submission_id: used, registration: ENTRY)
      assert_response :conflict
      assert_equal 1, calls.size
    end
  end

  test "registering from a clinic the scheduler cannot book on is refused" do
    sign_in(%w[scheduling_user scheduling_registration])
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5/registrations/new", params: BOOKING
      assert_response :forbidden
    end
  end
end
