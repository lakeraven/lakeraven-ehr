# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require_relative "support/supplemental_provider_config_helper"
require_relative "support/global_store_isolation"
require_relative "support/host_role_expectations"
require_relative "support/fake_gateway"
require_relative "support/stub_helpers"
require_relative "support/ihs_feature_availability_test_helper"
require "rpms_rpc/mock_client"
require_relative "support/mock_session_user"

# Baseline RpmsRpc mock seeds. Installed at load and again before every
# example (GlobalStoreIsolation) so a test that adds seeds cannot leak
# them into the next example.
BASELINE_MOCK_SEEDS = lambda do |m|
  # Patients (DFN 1-3)
  m.seed(:patient_select, "1", { name: "Anderson,Alice", sex: "F", dob: Date.parse("1980-05-15"), ssn: "111-11-1111", age: 45 })
  m.seed(:patient_select, "2", { name: "MOUSE,MICKEY M", sex: "M", dob: Date.parse("2010-02-14"), ssn: "000009999", age: 16 })
  m.seed(:patient_select, "3", { name: "DOE,JANE", sex: "F", dob: Date.parse("1990-12-25"), ssn: "555667777", age: 35 })

  # patient_id_info returns ORWPT ID INFO as IDINFO^ORWPT writes it
  # (SSN/DOB/sex/veteran/SC%/ward/room-bed/name, rpms-rpc #309) — not the
  # race code and site the earlier mapping read there, and not the extended demographics
  # that the prior mapping hallucinated. Address, phone, service_area and
  # coverage_type still have NO known RPC source — the old "BHDPTRPC, not
  # installed on staging" attribution was itself unverified (see rpms-rpc
  # docs/RPC_COVERAGE.md, "BHDPTRPC provenance"); a real demographics read
  # path for those is future work (lakeraven-ehr#564). Tests that need them
  # construct Patient.new(...) directly rather than going through the gateway.
  #
  # TRIBAL detail is no longer in that list. RPMS stores it in #9000001
  # (^AUPNPAT) and it is read via DDR GETS ENTRY DATA, seeded below.
  m.seed(:patient_id_info, "1", {
    ssn: "111-11-1111", dob: Date.parse("1980-05-15"), sex: "F",
    veteran: "", ward_location: "", name: "Anderson,Alice"
  })
  m.seed(:patient_id_info, "2", {
    ssn: "000009999", dob: Date.parse("2010-02-14"), sex: "M",
    veteran: "", ward_location: "", name: "MOUSE,MICKEY M"
  })
  m.seed(:patient_id_info, "3", {
    ssn: "555667777", dob: Date.parse("1990-12-25"), sex: "F",
    veteran: "", ward_location: "", name: "DOE,JANE"
  })

  # Tribal detail for DFN 1 — #9000001 (^AUPNPAT) via DDR GETS ENTRY DATA,
  # which is where RPMS actually keeps it. Wire form per field is
  # FILE^IEN^FIELD^INTERNAL^EXTERNAL. Fields: .07 enrollment no, 1108 tribe
  # (pointer -> TRIBE #9999999.03), 1109 tribe quantum, 1110 Indian blood
  # quantum, 1111 classification/beneficiary (pointer -> BENEFICIARY
  # #9999999.25), 1112 eligibility status (set I/D/C/P), 1118 current
  # community. Synthetic values throughout.
  m.seed(:ddr_gets_entry_data,
    RpmsRpc::DdrFileman.gets_entry_param(
      file: "9000001", iens: "1,",
      fields: ".07;1108;1109;1110;1111;1112;1118", flags: "IE"
    ).to_s,
    <<~TRIBAL.chomp)
      [Data]
      9000001^1^.07^EXNH-12345^EXNH-12345
      9000001^1^1108^41^Example Tribe
      9000001^1^1109^4/4^4/4
      9000001^1^1110^4/4^4/4
      9000001^1^1111^1^Indian/Alaska Native
      9000001^1^1112^I^Indian/Alaska Native
      9000001^1^1118^Example Community^Example Community
    TRIBAL

  # The SSN index holds the SSN without punctuation; Patient.find_by_ssn
  # strips it before the call (rpms-rpc #352).
  m.seed(:patient_ssn, "111111111", { dfn: 1, name: "Anderson,Alice", ssn: "111111111" })

  # ORWPT LIST ALL answers a page of the name index, { dfn:, name: } rows,
  # whatever the start text (rpms-rpc #352): seeded unfiltered, so the
  # gateway's own filtering is what a search test exercises.
  m.seed_collection(:patient_list,
    [
      { dfn: 1, name: "Anderson,Alice" },
      { dfn: 2, name: "MOUSE,MICKEY M" },
      { dfn: 3, name: "DOE,JANE" }
    ])

  m.seed_collection(:practitioner_list,
    [ { ien: 101, name: "MARTINEZ,SARAH", title: "MD" }, { ien: 102, name: "CHEN,JAMES", title: "DO" } ],
    filter_field: :name)

  # Institution IEN 1 (#4) and hospital location IEN 1 (#44): DDR GETS ENTRY
  # DATA, which Organization.find and Location.find read since rpms-rpc
  # #379/#377 (the BHDO INST DATA / HOSP LOC DATA names were registered
  # nowhere). Wire form per field is FILE^IEN^FIELD^INTERNAL^EXTERNAL; #4
  # has no phone field. Synthetic values throughout.
  m.seed(:ddr_gets_entry_data,
    RpmsRpc::DdrFileman.gets_entry_param(
      file: RpmsRpc::Organization::FILE, iens: "1,",
      fields: RpmsRpc::Organization::FIELDS.join(";"), flags: "IE"
    ).to_s,
    <<~INSTITUTION.chomp)
      [Data]
      4^1^.01^Example Health Center^Example Health Center
      4^1^99^463^463
      4^1^1.01^500 Example Way^500 Example Way
      4^1^1.03^Anchorage^Anchorage
      4^1^.02^2^ALASKA
      4^1^1.04^99508^99508
    INSTITUTION
  m.seed(:ddr_gets_entry_data,
    RpmsRpc::DdrFileman.gets_entry_param(
      file: RpmsRpc::Location::FILE, iens: "1,",
      fields: RpmsRpc::Location::FIELDS.values.join(";"), flags: "IE"
    ).to_s,
    <<~LOCATION.chomp)
      [Data]
      44^1^.01^Primary Care Clinic^Primary Care Clinic
      44^1^1^PCC^PCC
      44^1^2^C^CLINIC
      44^1^3.5^1^Example Health Center
    LOCATION

  # VFC eligibility: BGOVIMM2 GETELIG (the code table) and BGOVIMM GETVFC
  # (DFN 1's default, which answers a label, not a code), read by
  # Eligibility.codes and .for_patient since rpms-rpc #376.
  m.seed_collection(:vfc_eligibility_codes, [
    { ien: 1, code: "V01", label: "Not VFC eligible" },
    { ien: 2, code: "V02", label: "VFC eligible - Medicaid" },
    { ien: 3, code: "V03", label: "VFC eligible - Uninsured" },
    { ien: 4, code: "V04", label: "Am Indian/AK Native" },
    { ien: 5, code: "V05", label: "VFC eligible - FQHC" },
    { ien: 6, code: "V06", label: "VFC eligible - State specific" },
    { ien: 7, code: "V07", label: "VFC eligible - Local specific" }
  ])
  m.seed(:vfc_default, "1", { ihs_site: 1, age: 45, default_label: "Am Indian/AK Native" })

  # Tribal enrollment / eligibility seeds REMOVED with the rpms-rpc 0.3.0 bump.
  # #235 deleted the invented placeholder mappings these seeded against
  # (:tribal_enrollment, :tribal_validation, :enrollment_eligibility,
  # :service_unit, :tribe_info — "no known server implementation") and rebuilt
  # RpmsRpc::Tribal on real DDR FileMan reads. The tribal tests now stub
  # TribalEnrollmentGateway / RpmsRpc::Tribal at the API boundary rather than
  # seeding removed wire mappings. Interim eligibility behaviour is fail-closed
  # (undetermined ⇒ not eligible); the eligibility_status (I/D/C/P) product
  # mapping is tracked in #520 and is out of Sprint 1 (BH-only) scope.

  # Vitals (ORQQVI VITALS) for patient DFN 1
  m.seed_keyed_collection(:vitals, "1", [
    { measurement_ien: 1001, type: "BP",  value: "120/80", units: "mm[Hg]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
    { measurement_ien: 1002, type: "P",   value: "72",     units: "/min",   recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
    { measurement_ien: 1003, type: "T",   value: "98.6",   units: "[degF]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
    { measurement_ien: 1004, type: "R",   value: "16",     units: "/min",   recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
    { measurement_ien: 1005, type: "POX", value: "98",     units: "%",      recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
    { measurement_ien: 1006, type: "WT",  value: "150",    units: "[lb_av]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) },
    { measurement_ien: 1007, type: "HT",  value: "65",     units: "[in_i]", recorded_date: Time.new(2025, 1, 15, 9, 0, 0) }
  ])

  # Test users
  m.seed_user("301", credentials: "testprovider;test123", name: "PROVIDER,TEST", role: :provider)
  m.seed_user("302", credentials: "testnurse;test123", name: "NURSE,TEST", role: :nurse)
  m.seed_user("303", credentials: "testclerk;test123", name: "CLERK,TEST", role: :clerk)
  m.seed_user("304", credentials: "lindarodriguez;test123", name: "RODRIGUEZ,LINDA", role: :case_manager)
  # DUZ 304's KEYS multiple (#200.051), which Authentication.user_security_keys
  # reads with DDR LISTER since rpms-rpc #374: IEN^KEY-name rows.
  m.seed_text(:ddr_lister,
    RpmsRpc::DdrFileman.lister_param(file: "200.051", iens: ",304,", fields: "@;.01").to_s,
    <<~KEYS.chomp)
      [Data]
      1^PRCFA SUPERVISOR
      2^OR CPRS GUI CHART
    KEYS

  # Practitioner — ORWU USERINFO is single-session-user (per rr-fyf); the
  # mock dispatches on "" since the wrapper passes no params. Test code
  # that "looks up" IEN 101 works iff the seeded duz matches; IEN 102 or
  # any other returns nil. The practitioner_list (ORWU NEWPERS) is a
  # genuine multi-record search and continues to surface both.
  #
  # Seeded after the test users: MockClient#seed_user writes the same
  # session-user reply for each user it seeds (rpms-rpc 0.4), so seeding
  # it first would leave the last test user as the session user.
  m.seed(:practitioner_info, "", {
    duz: 101, name: "MARTINEZ,SARAH", user_class: 3,
    kernel_domain: "DEMO.IHS.GOV", site_ien: 8904
  })
end

RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)

# Scripted RPC broker for the BPRM reg/sched/ADT twin gateway tests.
#
# The reg/sched gateways call RpmsRpc.client.call_rpc(rpc_name, *params)
# directly and parse the caret response, so a gateway unit test just needs a
# client that (a) records the calls it received and (b) returns a scripted
# response per RPC name. `on(rpc, *responses)` queues responses (a single
# response is reused for every call; multiple are consumed in order — handy
# for composite flows like rebook). `raise_with` simulates a broker-unreachable
# socket error. Swap it in with `use_broker(fake) { ... }` from a test.
class FakeBroker
  attr_reader :calls

  def initialize
    @calls = []
    @responses = {}
    @raise = nil
    @default = ""
  end

  def on(rpc, *responses)
    @responses[rpc] = responses
    self
  end

  def raise_with(error)
    @raise = error
    self
  end

  def call_rpc(rpc, *params)
    @calls << { rpc: rpc, params: params }
    raise @raise if @raise

    queue = @responses[rpc]
    return @default if queue.nil? || queue.empty?
    return queue.first if queue.length == 1

    queue.shift
  end

  # The REAL clients (BmxClient, CiaClient) expose a public `call_rpc_raw`
  # that executes an RPC without response parsing. The fake models it so a
  # wrapper that forwards it can be SEEN doing so — a mock without the real
  # client's surface cannot express the bypass (SOFTWARE-FACTORY: a mock that
  # cannot express a failure is not evidence against it).
  def call_rpc_raw(rpc, *params)
    call_rpc(rpc, *params)
  end

  # Also on the real clients' public surface; must never be reachable
  # through an audited wrapper.
  def read_response = @default

  # The REST of the production clients' public surface (BmxClient/CiaClient:
  # connection, credential and raw-execution methods), as LOUD stubs. They
  # exist so `respond_to?` is true — a wrapper regression back to
  # "forward anything the client answers" then reaches them and fails the
  # suite audibly for EVERY method, not just call_rpc_raw.
  %i[connect disconnect authenticate signon_setup authenticated? duz
     call_rpc_global_array create_context set_authenticated].each do |name|
    define_method(name) do |*_args, **_options|
      raise "GATE: #{name} reached the fake through a wrapper that should refuse to forward it"
    end
  end

  def connected? = true
  def hostname = "fake-broker.test"
  def received_calls = @calls
  def calls_for(rpc) = @calls.select { |c| c[:rpc] == rpc }
  def last_call = @calls.last
end

# Install a FakeBroker as RpmsRpc.client for the duration of the block,
# restoring the shared MockClient afterward.
module BrokerStubbing
  def use_broker(fake)
    original = RpmsRpc.configuration.client
    RpmsRpc.configure { |c| c.client = fake }
    yield fake
  ensure
    RpmsRpc.configure { |c| c.client = original }
  end
end

# Shared auth helper for integration tests.
module SmartAuthTestHelper
  def setup_smart_auth(scopes: "system/*.read")
    @oauth_app = Doorkeeper::Application.create!(
      name: "test", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @oauth_app, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def teardown_smart_auth
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
  end
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = "#{File.expand_path('fixtures', __dir__)}/files"
  ActiveSupport::TestCase.fixtures :all
end

ActiveSupport::TestCase.include GlobalStoreIsolation
ActiveSupport::TestCase.include StubHelpers
