# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/patient_application"

# rpms-ux S-REG-03.3 to 03.5: the front desk records that a patient applied for
# coverage, and what happened. RpmsRpc::PatientApplication (AG's PATIENT
# APPLICATIONS, 9000045) is stood in for at the gem boundary;
# test/integration/live_registration_applications_test.rb runs the screens
# against a real RPMS.
class RegistrationApplicationsTest < ActionDispatch::IntegrationTest
  DFN = 990_010
  HEADER = { name: "JULIET,QUINN", dob: Date.new(1985, 3, 1), sex: "F", mrn: "990010" }.freeze
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  TYPES = [ { ien: 1, name: "MEDICAID FORM 100" }, { ien: 2, name: "MEDICARE FORM 1034" } ].freeze
  APPLIED = Date.current - 10

  ON_FILE = [
    { ien: 3, obtained: APPLIED, type: { ien: 1, name: "MEDICAID FORM 100" }, status: "P", status_name: "PENDING",
      received_by: 207, case: nil,
      submissions: [ { ien: 1, date: APPLIED + 1, via: "O", submitted_by: 207, reason: nil, statuses: [] } ] }
  ].freeze

  def sign_in(keys = "registration_menu")
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys }
  end

  # Stands in for RpmsRpc::PatientApplication, the coverage read and the patient header.
  def with_rpms(applications: ON_FILE, add: { success: true, application: 4, submission: 2 },
                update: { success: true, dated: true })
    calls = []
    stubs = {
      RpmsRpc::PatientApplication.singleton_class => {
        types: ->(*) { TYPES },
        for_patient: applications.is_a?(Proc) ? applications : ->(_dfn) { applications },
        add: ->(dfn, **kw) { calls << [ :add, dfn, kw ]; add.is_a?(Proc) ? add.call : add },
        update_status: ->(dfn, **kw) { calls << [ :update_status, dfn, kw ]; update }
      },
      RpmsRpc::Coverage.singleton_class => { on_file: ->(_dfn) { { medicaid: [], medicare: [], private: [] } } },
      RpmsRpc::Patient.singleton_class => { brief_header: ->(dfn) { dfn.to_i == DFN ? HEADER : nil } }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield calls
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  test "S-REG-03.3 the coverage page lists the patient's applications with when they applied and the status" do
    sign_in
    with_rpms { get "#{BASE}/coverage" }

    assert_response :ok
    assert_select "#applications tr[data-application='3'][data-status='P'] td", text: "MEDICAID FORM 100"
    assert_select "#applications tr[data-application='3'] td", text: APPLIED.strftime("%b %-d, %Y")
    assert_select "#applications tr[data-application='3'] td", text: /\(Online\)/
    assert_select "#applications tr[data-application='3'] [data-status-badge]", text: "Pending"
    assert_select "#add-application"
  end

  test "S-REG-03.3 an application is recorded through RPMS with the type, the dates and the clerk" do
    sign_in
    with_rpms do |calls|
      post "#{BASE}/applications", params: { application: { type_ien: "1", applied_on: APPLIED.iso8601,
                                                            submitted_on: (APPLIED + 1).iso8601, submitted_via: "M" } }

      assert_redirected_to "#{BASE}/coverage#applications-section"
      _, dfn, kw = calls.find { |c| c.first == :add }
      assert_equal DFN, dfn
      assert_equal({ obtained: APPLIED, type: 1, submitted: APPLIED + 1, via: "M", received_by: 207, submitted_by: 207 }, kw)
    end
  end

  test "S-REG-03.3 a date in the future or no kind of application is refused before RPMS is asked" do
    sign_in
    with_rpms do |calls|
      post "#{BASE}/applications", params: { application: { type_ien: "", applied_on: (Date.current + 1).iso8601 } }

      assert_response :unprocessable_content
      assert_select "#application-errors", text: /choose the kind of application/
      assert_select "#application-errors", text: /cannot be in the future/
      assert_empty calls
    end
  end

  test "S-REG-03.3 RPMS's refusal is shown in its words" do
    sign_in
    with_rpms(add: { success: false, error: :exists, message: "an application obtained on that date is already on file" }) do
      post "#{BASE}/applications", params: { application: { type_ien: "1", applied_on: APPLIED.iso8601 } }

      assert_response :unprocessable_content
      assert_select "#application-alert", text: /already on file/
    end
  end

  test "S-REG-03.3 an answer RPMS never gave is said to be unknown" do
    sign_in
    with_rpms(add: -> { raise RpmsRpc::Client::ConnectionError, "gone" }) do
      post "#{BASE}/applications", params: { application: { type_ien: "1", applied_on: APPLIED.iso8601 } }

      assert_response :service_unavailable
      assert_select "#application-alert", text: /did not say whether/
    end
  end

  test "S-REG-03.4 approved or denied is recorded with its date" do
    sign_in
    with_rpms do |calls|
      post "#{BASE}/applications/3/status", params: { status: "A", status_on: Date.current.iso8601 }

      assert_redirected_to "#{BASE}/coverage#applications-section"
      assert_equal "Application marked approved.", flash[:notice]
      assert_equal [ :update_status, DFN, { application: 3, status: "A", date: Date.current } ], calls.find { |c| c.first == :update_status }
    end
  end

  test "S-REG-03.4 an outcome dated in the future is refused before RPMS is asked" do
    sign_in
    with_rpms do |calls|
      post "#{BASE}/applications/3/status", params: { status: "A", status_on: (Date.current + 1).iso8601 }

      assert_equal "Choose what happened to the application and a date that is not in the future.", flash[:alert]
      assert_empty calls
    end
  end

  test "S-REG-03.5 an application entered in error stays listed and offers no change" do
    sign_in
    with_rpms(applications: [ ON_FILE.first.merge(status: "E", status_name: "ENTERED IN ERROR") ]) do
      get "#{BASE}/coverage"
    end

    assert_select "#applications tr[data-application='3'][data-status='E'] [data-status-badge]", text: "Entered in error"
    assert_select "#application-status-3", count: 0
  end

  test "S-REG-03.3 when RPMS does not answer for applications, the coverage still shows and says so" do
    sign_in
    with_rpms(applications: ->(_dfn) { raise RpmsRpc::Client::RpcError, "no reply" }) { get "#{BASE}/coverage" }

    assert_response :ok
    assert_select "#applications-unavailable"
  end

  test "a view-only registration user sees applications but cannot record one" do
    sign_in("registration_view_only")
    with_rpms do |calls|
      get "#{BASE}/coverage"
      assert_select "#applications tr[data-application='3']"
      assert_select "#add-application", count: 0
      assert_select "#application-status-3", count: 0

      post "#{BASE}/applications", params: { application: { type_ien: "1", applied_on: APPLIED.iso8601 } }
      assert_response :forbidden
      assert_empty calls
    end
  end
end
