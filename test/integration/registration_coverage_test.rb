# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-03: the front desk records a patient's Medicaid, Medicare and
# private insurance so the visit can be billed. RPMS (AG's registration
# windows, through RpmsRpc::Coverage) is stood in for at the gem boundary;
# test/integration/live_registration_coverage_test.rb runs the same screens
# against a real RPMS.
class RegistrationCoverageTest < ActionDispatch::IntegrationTest
  include BrowserFormHelper
  DFN = 990_049
  HEADER = { name: "ZEPHYR,QUINN", dob: Date.new(1983, 8, 18), sex: "F", mrn: "990049" }.freeze

  ON_FILE = {
    medicaid: [
      { record_ien: "3", payer: "MEDICAID", number: "ZZ1234567", state: "WASHINGTON", active: true,
        eligibility: [ { ien: "3260101", starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31), coverage: "" } ] },
      { record_ien: "4", payer: "MEDICAID", number: "ZZLAPSED1", state: "WASHINGTON", active: false,
        eligibility: [ { ien: "3240101", starts_on: Date.new(2024, 1, 1), ends_on: Date.new(2025, 6, 30), coverage: "" } ] }
    ],
    medicare: [
      { record_ien: "990049", payer: "MEDICARE", number: "1EG4TE5MK73", suffix: "", active: true,
        eligibility: [ { ien: "1", starts_on: Date.new(2026, 1, 1), ends_on: nil, coverage: "PART B" } ] }
    ],
    private: [
      { record_ien: "1", payer: "VETERANS MEDICAL BENEFIT", payer_ien: "5", number: "ZZM49", policy_holder: "ZEPHYR,QUINN",
        starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2027, 12, 31), active: true }
    ]
  }.freeze

  def sign_in(keys) = post("/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys })

  def path = "/lakeraven-ehr/registration/patients/#{DFN}/coverage"

  # Stands in for RpmsRpc::Coverage and the patient header; records each write.
  def with_rpms(on_file: ON_FILE, add: { success: true }, insurers: [], states: [])
    @writes = []
    writes = @writes
    stubs = {
      RpmsRpc::Coverage.singleton_class => {
        on_file: on_file.is_a?(Proc) ? on_file : ->(_dfn) { on_file },
        add_medicaid: ->(dfn, **kw) { writes << [ :medicaid, dfn, kw ]; add },
        add_medicare: ->(dfn, **kw) { writes << [ :medicare, dfn, kw ]; add },
        add_private_insurance: ->(dfn, **kw) { writes << [ :private, dfn, kw ]; add },
        insurers: ->(**) { insurers }
      },
      RpmsRpc::Patient.singleton_class => { brief_header: ->(dfn) { dfn.to_i == DFN ? HEADER : nil } },
      RpmsRpc::DdrFileman.singleton_class => { lister: ->(**) { { entries: states.map { |s| { ien: s[:ien], pieces: [ s[:name] ] } }, error: false } } }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  test "S-REG-03.1 the front desk sees each payer, member number, dates and whether it is in force today" do
    sign_in("registration_menu")
    with_rpms { get path }

    assert_response :ok
    assert_select "#coverage tbody tr", 4
    assert_select "#coverage tr[data-number='ZZ1234567'][data-active='true'] td", text: /MEDICAID/
    assert_select "#coverage tr[data-number='ZZ1234567'] [data-period]", text: /Jan 1, 2026\s+to\s+Dec 31, 2026/
    assert_select "#coverage tr[data-number='ZZ1234567'] td", text: "In force"
    assert_select "#coverage tr[data-number='ZZLAPSED1'][data-active='false'] td", text: "Not in force"
    assert_select "#coverage tr[data-kind='medicare'] [data-period]", text: /no end date \(PART B\)/
    assert_select "#coverage tr[data-kind='private'] td", text: /VETERANS MEDICAL BENEFIT/
    assert_select "#add-medicaid"
  end

  test "S-REG-03.1 a Medicaid number, its state and eligibility dates are sent to AG as entered" do
    sign_in("registration_menu")
    with_rpms do
      post path, params: { coverage: { kind: "medicaid", number: "zz 4900001", state_ien: "48",
                                       starts_on: "2026-01-01", ends_on: "2026-12-31" } }

      assert_redirected_to path
      kind, dfn, sent = @writes.sole
      assert_equal [ :medicaid, DFN ], [ kind, dfn ]
      assert_equal({ number: "ZZ4900001", state_ien: 48, coverage: nil, effective_on: "01/01/2026", ends_on: "12/31/2026" }, sent)
      follow_redirect!
      assert_select "#coverage-saved", text: /Medicaid coverage saved/
    end
  end

  test "S-REG-03.1 Medicare is filed with its part, under the patient's name" do
    sign_in("registration_menu")
    with_rpms do
      post path, params: { coverage: { kind: "medicare", number: "1EG4TE5MK73", part: "B", starts_on: "2026-01-01" } }

      assert_redirected_to path
      assert_equal({ name: "ZEPHYR,QUINN", number: "1EG4TE5MK73", part: "B", effective_on: "01/01/2026", ends_on: nil },
                   @writes.sole.last)
    end
  end

  test "S-REG-03.1 a private policy names the insurer, the policy holder and the member number" do
    sign_in("registration_menu")
    with_rpms do
      post path, params: { coverage: { kind: "private", insurer_ien: "5", policy_holder: "zephyr,quinn", number: "ZZM49",
                                       starts_on: "2026-01-01", ends_on: "2027-12-31" } }

      assert_redirected_to path
      assert_equal({ insurer_ien: 5, policy_holder: "ZEPHYR,QUINN", member_number: "ZZM49",
                     effective_on: "01/01/2026", ends_on: "12/31/2027" }, @writes.sole.last)
    end
  end

  test "an entry with no start date, or an end before the start, is refused before RPMS is asked" do
    sign_in("registration_menu")
    with_rpms do
      post path, params: { coverage: { kind: "medicaid", number: "ZZ1", state_ien: "48", starts_on: "2026-06-01", ends_on: "2026-01-01" } }
      assert_response :unprocessable_content
      assert_select "#coverage-errors", text: /on or after the start date/

      post path, params: { coverage: { kind: "medicaid", number: "ZZ1", starts_on: "" } }
      assert_response :unprocessable_content
      assert_select "#coverage-errors", text: /State that issued the number is required/
    end
    assert_empty @writes
  end

  test "when AG refuses, the clerk sees AG's reason and the form keeps what was typed" do
    sign_in("registration_menu")
    with_rpms(add: { success: false, error: :coverage_rejected, message: "The value is not valid" }) do
      post path, params: { coverage: { kind: "medicare", number: "1EG4TE5MK73", part: "A", starts_on: "2026-01-01" } }
    end

    assert_response :unprocessable_content
    assert_select "#coverage-alert", text: /RPMS did not save the Medicare coverage: The value is not valid/
    assert_select "input[name='coverage[number]'][value='1EG4TE5MK73']"
  end

  test "an add with no answer is never reported as saved or as not saved" do
    sign_in("registration_menu")
    with_rpms(add: nil) do
      post path, params: { coverage: { kind: "medicare", number: "1EG4TE5MK73", part: "A", starts_on: "2026-01-01" } }
    end

    assert_response :service_unavailable
    assert_select "#coverage-alert", text: /did not say whether/
  end

  test "the state look-up posts the form back, so the member number stays out of the URL" do
    sign_in("registration_menu")
    with_rpms(states: [ { ien: "48", name: "WASHINGTON" } ]) do
      post "#{path}/new", params: { state_search: "WASH", coverage: { kind: "medicaid", number: "ZZ1" } }
    end

    assert_response :ok
    assert_select "label[data-state='48']", text: /WASHINGTON/
    assert_select "input[name='coverage[number]'][value='ZZ1']"
  end

  test "a private policy's insurer is chosen from AG's private insurers" do
    sign_in("registration_menu")
    insurers = [ { ien: "5", name: "VETERANS MEDICAL BENEFIT", city: "ANYTOWN", state: "WASHINGTON", type: "PRIVATE" },
                 { ien: "3", name: "MEDICAID", city: "ANYTOWN", state: "WASHINGTON", type: "MEDICAID FI" } ]
    with_rpms(insurers: insurers) do
      post "#{path}/new", params: { insurer_search: "V", coverage: { kind: "private" } }
    end

    assert_select "label[data-insurer='5']"
    assert_select "label[data-insurer='3']", 0
  end

  test "a view-only user sees coverage but cannot add it" do
    sign_in("registration_view_only")
    with_rpms do
      get path
      assert_response :ok
      assert_select "#add-medicaid", 0

      post path, params: { coverage: { kind: "medicare", number: "1EG4TE5MK73", part: "A", starts_on: "2026-01-01" } }
      assert_response :forbidden
    end
    assert_empty @writes
  end

  test "when RPMS refuses the read, the clerk is told why instead of seeing no coverage" do
    sign_in("registration_menu")
    refuse = ->(_dfn) { raise RpmsRpc::Client::RpcRefusedError, "4 Access denied for remote procedure: AGG BUILD WINDOW MANY" }
    with_rpms(on_file: refuse) { get path }

    assert_response :forbidden
    assert_select "#coverage-refused"
    assert_select "#no-coverage", 0
  end

  test "when RPMS does not answer, the page says so instead of showing no coverage" do
    sign_in("registration_menu")
    with_rpms(on_file: nil) { get path }

    assert_response :service_unavailable
    assert_select "#coverage-unavailable"
    assert_select "#no-coverage", 0
  end

  # #896: a browser sends the form's own token; the look-up must accept it.
  test "Find state is accepted with forgery protection on, as in a browser" do
    sign_in("registration_menu")
    with_rpms(states: [ { ien: "48", name: "WASHINGTON" } ]) do
      with_forgery_protection do
        get "#{path}/new", params: { kind: "medicaid" }
        press "Find state", fill: { "state_search" => "WASH", "coverage[number]" => "ZZ1" }
      end
    end

    assert_response :ok
    assert_select "label[data-state='48']", text: /WASHINGTON/
    assert_select "input[name='coverage[number]'][value='ZZ1']"
    assert_empty @writes
  end
end
