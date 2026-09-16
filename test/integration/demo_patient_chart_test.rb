# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Read-only, AUTHENTICATED demo patient chart (issue #452).
#
# Exercises the content-negotiated /patients/:dfn endpoint against the test/dummy
# host with the shared synthetic seed set — the SAME data the SPIKE dev
# initializer loads. Installs a fully-seeded mock for the test and restores
# the suite-wide shared mock afterward so global state stays clean.
#
# Auth is enforced for BOTH representations (HTML + FHIR JSON): SMART bearer
# token (Doorkeeper), per-resource read scope, and patient-context binding.
class DemoPatientChartTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    @original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    setup_smart_auth(scopes: "system/*.read") # @headers => full read token
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::ScreeningResponse.delete_all
    RpmsRpc.configure { |c| c.client = @original_client }
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def token_with(scopes:, resource_owner_id: nil)
    app = Doorkeeper::Application.create!(
      name: "scoped", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    Doorkeeper::AccessToken.create!(
      application: app, scopes: scopes, resource_owner_id: resource_owner_id, expires_in: 3600
    )
  end

  # -- HTML representation (authenticated) -------------------------------------

  test "HTML chart renders the patient banner and every clinical section" do
    get "/patients/1", headers: @headers

    assert_response :ok
    assert_equal "text/html", response.media_type
    body = response.body

    assert_includes body, "Lakeraven EHR"
    assert_includes body, "Alice Anderson"
    assert_includes body, "Type 2 diabetes mellitus"
    assert_includes body, "E11.9"
    assert_includes body, "Lisinopril 10mg"
    assert_includes body, "Metformin 500mg"
    assert_includes body, "Penicillin"
    assert_includes body, "Shellfish"
    assert_includes body, "128/82"
    assert_includes body, "COVID-19 Vaccine"
    assert_includes body, "Riverbend Family Health Clinic"
    assert_includes body, "View as FHIR"
  end

  test "HTML chart badges each screening with a class built from the WHOLE band" do
    seed_screening(band: "moderately severe", total: 18)
    get "/patients/1", headers: @headers

    assert_response :ok
    assert_select "span.badge.sev-moderately-severe", text: "moderately severe"
    # Regression: the class came from the band's first word, so this badge
    # rendered as `sev-moderately` — matching no rule in the stylesheet.
    assert_select "span.badge.sev-moderately", false
    assert_no_match(/sev-moderately"/, response.body)
    # Whatever class is emitted must have a rule behind it.
    assert_includes response.body, ".badge.sev-moderately-severe{"
  end

  test "HTML chart badges a single-word band unchanged" do
    seed_screening(band: "minimal", total: 2)
    get "/patients/1", headers: @headers

    assert_select "span.badge.sev-minimal", text: "minimal"
    assert_includes response.body, ".badge.sev-minimal{"
  end

  # -- FHIR JSON representation (authenticated) --------------------------------

  test "chart .json returns a FHIR Bundle with the FHIR content type" do
    get "/patients/1.json", headers: @headers

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type

    bundle = JSON.parse(response.body)
    assert_equal "Bundle", bundle["resourceType"]
    assert_equal "searchset", bundle["type"]
    assert bundle["total"].to_i.positive?

    resource_types = bundle["entry"].map { |e| e.dig("resource", "resourceType") }
    %w[Patient Condition MedicationRequest AllergyIntolerance Observation].each do |type|
      assert_includes resource_types, type, "Bundle should contain a #{type}"
    end
  end

  test "Accept: application/fhir+json also yields the Bundle" do
    get "/patients/1", headers: @headers.merge("Accept" => "application/fhir+json")

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  # -- FHIR Bundle conformance polish ------------------------------------------

  test "FHIR Bundle carries id, meta.lastUpdated, self link, and per-entry fullUrl" do
    get "/patients/1.json", headers: @headers
    bundle = JSON.parse(response.body)

    assert bundle["id"].present?, "Bundle should have an id"
    assert bundle.dig("meta", "lastUpdated").present?, "Bundle should have meta.lastUpdated"
    assert_equal bundle["entry"].length, bundle["total"]

    self_link = Array(bundle["link"]).find { |l| l["relation"] == "self" }
    assert self_link, "Bundle should have a self link"
    assert self_link["url"].present?

    assert bundle["entry"].all? { |e| e["fullUrl"].present? }, "every entry needs a fullUrl"
    assert bundle["entry"].all? { |e| e.dig("search", "mode") == "match" },
      "searchset entries should carry search.mode=match"
  end

  test "AllergyIntolerance, Observation, and Encounter entries carry an id with resolvable (non-urn) fullUrls" do
    get "/patients/1.json", headers: @headers
    bundle = JSON.parse(response.body)

    %w[AllergyIntolerance Observation Encounter].each do |type|
      entries = bundle["entry"].select { |e| e.dig("resource", "resourceType") == type }
      assert entries.any?, "expected at least one #{type} entry"

      entries.each do |e|
        assert e.dig("resource", "id").present?, "#{type} resource should carry an id"
        refute e["fullUrl"].start_with?("urn:uuid:"), "#{type} fullUrl should be resolvable, got #{e['fullUrl']}"
        # fullUrls live under the engine's real mount point (test/dummy mounts
        # it at /lakeraven-ehr), NOT a fictitious /fhir prefix.
        assert_includes e["fullUrl"], "/lakeraven-ehr/#{type}/", "#{type} fullUrl should be a REST URL under the engine mount"
      end
    end

    # Encounter and Observation ids are deterministic/stable across requests.
    first_ids = %w[Encounter Observation].index_with do |type|
      bundle["entry"].find { |e| e.dig("resource", "resourceType") == type }.dig("resource", "id")
    end
    get "/patients/1.json", headers: @headers
    again = JSON.parse(response.body)["entry"]
    first_ids.each do |type, id|
      id_again = again.find { |e| e.dig("resource", "resourceType") == type }.dig("resource", "id")
      assert_equal id, id_again, "#{type} id should be stable across requests"
    end
  end

  test "vital-sign Observations carry effectiveDateTime and numeric valueQuantity" do
    get "/patients/1.json", headers: @headers
    bundle = JSON.parse(response.body)

    observations = bundle["entry"].map { |e| e["resource"] }
      .select { |r| r["resourceType"] == "Observation" }
    assert observations.any?

    observations.each do |obs|
      assert obs["effectiveDateTime"].present?, "vital sign needs effective[x] (required 1..1)"
      value = obs.dig("valueQuantity", "value")
      assert value.is_a?(Numeric), "Quantity.value must be a JSON number, got #{value.class}" if value
    end
  end

  # -- Authentication: fail closed, no token -----------------------------------

  test "no token -> 401 for HTML, and NOT a FHIR JSON body" do
    get "/patients/1"

    assert_response :unauthorized
    refute_equal "application/fhir+json", response.media_type
  end

  test "no token -> 401 FHIR OperationOutcome for .json" do
    get "/patients/1.json"

    assert_response :unauthorized
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
  end

  # -- Authorization: scope --------------------------------------------------

  test "token that cannot read Patient -> 403" do
    token = token_with(scopes: "system/Observation.read")
    get "/patients/1.json", headers: bearer(token)

    assert_response :forbidden
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  # -- Authorization: screening scores vs screening answers --------------------
  #
  # A screening yields TWO resource families with different sensitivities: the
  # total score (Observation) and the item-level answers (QuestionnaireResponse,
  # which includes what the patient said about PHQ-9 item 9). They are
  # authorized independently — NEITHER may be reachable only via the other's
  # scope. All four scope combinations are pinned.

  # Answers that genuinely sum to `total` — the row is validated for internal
  # consistency now (a score that disagrees with its own answers is not
  # storable), so a seed may not assert a total its answers do not support.
  def answers_summing_to(total, instrument = Lakeraven::EHR::ScreeningInstrument::PHQ9)
    base, extra = total.divmod(instrument.items.length)
    instrument.link_ids.each_with_index.to_h { |link_id, i| [ link_id, base + (i < extra ? 1 : 0) ] }
  end

  def seed_screening(band: "moderately severe", total: 18)
    answers = answers_summing_to(total)
    safety = Lakeraven::EHR::ScreeningInstrument::PHQ9.safety_link_id
    # A row whose answers disclose self-harm may only exist with
    # acknowledgement evidence: derive it rather than assert it.
    acknowledged = answers[safety].to_i.positive? ?
      { safety_flagged: true, safety_acknowledged_at: Time.utc(2026, 3, 1),
        safety_acknowledged_by: "99999" } : {}

    Lakeraven::EHR::ScreeningResponse.create!({
      patient_dfn: 1, encounter_ien: "2090061", instrument_key: "phq-9",
      answers: answers,
      total_score: total, severity_band: band,
      effective_at: Time.utc(2026, 3, 1), source: "clinician",
      administered_by: "99999"
    }.merge(acknowledged))
  end

  # The chart also emits VITALS as Observations, so asserting on the bare
  # resourceType would pass even if the screening score were missing. These
  # look for the screening total by its LOINC code specifically.
  PHQ9_TOTAL_CODE = "44261-6"

  def screening_resources(token)
    get "/patients/1.json", headers: bearer(token)
    assert_response :ok
    resources = JSON.parse(response.body)["entry"].map { |e| e["resource"] }
    [
      resources.select { |r| r.dig("code", "coding", 0, "code") == PHQ9_TOTAL_CODE },
      resources.select { |r| r["resourceType"] == "QuestionnaireResponse" }
    ]
  end

  test "both scopes -> the chart carries the score AND the answers" do
    seed_screening
    scores, answers = screening_resources(
      token_with(scopes: "system/Patient.read system/Observation.read system/QuestionnaireResponse.read"))

    assert_equal 1, scores.length
    assert_equal 1, answers.length
  end

  test "Observation scope only -> the score, and NOT the item-level answers" do
    seed_screening
    scores, answers = screening_resources(
      token_with(scopes: "system/Patient.read system/Observation.read"))

    assert_equal 1, scores.length
    assert_equal 18.0, scores.first.dig("valueQuantity", "value")
    assert_empty answers, "an Observation-scoped token must not see item-level answers"
  end

  test "QuestionnaireResponse scope only -> the answers, WITHOUT Observation scope" do
    # Regression: the answers were derived from a collection that only loaded
    # under Observation scope, so a QuestionnaireResponse-scoped token got
    # nothing at all — the exact case the separation is supposed to serve.
    seed_screening
    scores, answers = screening_resources(
      token_with(scopes: "system/Patient.read system/QuestionnaireResponse.read"))

    assert_equal 1, answers.length, "QuestionnaireResponse scope must stand on its own"
    assert_empty scores, "the score is an Observation and needs Observation scope"
  end

  test "neither scope -> no screening resources at all" do
    seed_screening
    scores, answers = screening_resources(token_with(scopes: "system/Patient.read"))

    assert_empty scores
    assert_empty answers
  end

  test "the answers carry the item-level responses the score does not expose" do
    seed_screening
    get "/patients/1.json",
        headers: bearer(token_with(scopes: "system/Patient.read system/QuestionnaireResponse.read"))

    qr = JSON.parse(response.body)["entry"]
      .map { |e| e["resource"] }.find { |r| r["resourceType"] == "QuestionnaireResponse" }
    item9 = qr["item"].find { |i| i["linkId"] == Lakeraven::EHR::ScreeningInstrument::PHQ9.safety_link_id }

    assert_not_nil item9, "the self-harm item is what this scope exists to protect"
    assert_equal "More than half the days", item9.dig("answer", 0, "valueCoding", "display")
  end

  # -- One bad engine-owned row must not take the chart down --------------------
  #
  # The screenings table is the engine's own side table. A row in it that no
  # longer serializes must cost at most that row — never the Patient, the
  # Conditions, the Medications, the Allergies or the Vitals, all of which come
  # from RPMS and are what the chart is FOR.

  def assert_chart_bundle_intact
    assert_response :ok
    bundle = JSON.parse(response.body)
    types = bundle["entry"].map { |e| e.dig("resource", "resourceType") }
    %w[Patient Condition MedicationRequest AllergyIntolerance Observation].each do |type|
      assert_includes types, type, "a malformed screening row cost the chart its #{type} resources"
    end
    bundle
  end

  test "an unserializable screening row does not 500 the chart bundle" do
    seed_screening
    broken = seed_screening(band: "minimal", total: 2)
    # Reachable by a direct write, a restore, or a row written before the
    # consistency validation existed.
    broken.update_column(:answers, broken.answers.merge(
      Lakeraven::EHR::ScreeningInstrument::PHQ9.link_ids.first => 9))

    get "/patients/1.json", headers: @headers
    bundle = assert_chart_bundle_intact

    questionnaires = bundle["entry"].map { |e| e["resource"] }
                                    .select { |r| r["resourceType"] == "QuestionnaireResponse" }
    assert_equal 1, questionnaires.length,
                 "the healthy screening is published and the malformed one is withheld, not partially published"
  end

  test "a screening row naming an unknown instrument does not 500 the chart" do
    seed_screening
    orphan = seed_screening(band: "minimal", total: 2)
    orphan.update_column(:instrument_key, "phq-2")

    get "/patients/1.json", headers: @headers
    bundle = assert_chart_bundle_intact

    scores = bundle["entry"].map { |e| e["resource"] }
                            .select { |r| r.dig("code", "coding", 0, "code") == PHQ9_TOTAL_CODE }
    assert_equal 1, scores.length, "the healthy screening must still carry its score"
  end

  # Validation runs on WRITE. A row can reach the table without ever meeting
  # it — a direct write, a restore, an import, a release older than the
  # validations — and publishing such a row as a `completed` QuestionnaireResponse
  # or a `final` Observation asserts something about data that disagrees with
  # itself.
  test "a row that contradicts its own answers is not published as a final score" do
    seed_screening
    contradictory = seed_screening(band: "minimal", total: 2)
    contradictory.update_column(:total_score, 999)

    get "/patients/1.json", headers: @headers
    bundle = assert_chart_bundle_intact

    scores = bundle["entry"].map { |e| e["resource"] }
                            .select { |r| r.dig("code", "coding", 0, "code") == PHQ9_TOTAL_CODE }
    assert_equal 1, scores.length, "only the row that agrees with itself may be published"
    assert_equal 18.0, scores.first.dig("valueQuantity", "value")
    assert_not_includes bundle["entry"].map { |e| e.dig("resource", "valueQuantity", "value") }, 999.0
  end

  # An unacknowledged disclosure can no longer reach the table at all — the
  # database refuses it (`screening_disclosure_requires_flag`), which is better
  # than withholding it on read, where the disclosure would be invisible rather
  # than flagged. Withholding still has to work for the corruptions that ARE
  # storable; that is the test above.
  test "an unacknowledged disclosure cannot be stored, not merely withheld" do
    row = seed_screening(band: "minimal", total: 2)
    safety = Lakeraven::EHR::ScreeningInstrument::PHQ9.safety_link_id

    assert_raises(ActiveRecord::StatementInvalid) do
      Lakeraven::EHR::ScreeningResponse.transaction(requires_new: true) do
        row.update_column(:answers, row.answers.merge(safety => 3))
      end
    end
  end

  test "a screening row naming an unknown instrument does not 500 the HTML chart" do
    seed_screening
    seed_screening(band: "minimal", total: 2).update_column(:instrument_key, "phq-2")

    get "/patients/1", headers: @headers

    assert_response :ok
    assert_includes response.body, "Alice Anderson"
  end

  # -- The context gate is a WEB-SURFACE control, not a system-wide one ---------
  #
  # Pinned deliberately, because the PR used to imply more. The clinician web
  # surface requires a patient's record to be OPENED — a deliberate, audited
  # act — before it will render item-level answers. The FHIR chart is a
  # different surface with different callers (apps, not browsers), and it is
  # governed by token scope and patient compartment; it has no session to bind
  # and requires no such open. Unifying the two on one CREDENTIAL (round 3, H2)
  # did not merge them into one SURFACE.
  #
  # So the honest claim is: the context gate makes CLINICIAN cross-patient
  # access deliberate and attributable. It is not a second lock on the data,
  # and a token holding QuestionnaireResponse scope reaches the answers through
  # the chart without it.
  test "the FHIR chart serves screening answers without a clinician context open" do
    seed_screening
    token = token_with(scopes: "system/Patient.read system/QuestionnaireResponse.read")

    get "/patients/1.json", headers: bearer(token)

    assert_response :ok
    answers = JSON.parse(response.body)["entry"].map { |e| e["resource"] }
                  .select { |r| r["resourceType"] == "QuestionnaireResponse" }
    assert_equal 1, answers.length,
                 "the chart is scope-governed; if this ever requires a session context, " \
                 "say so in the PR rather than leaving the two surfaces looking identical"
  end

  # This PR put screening answers into the chart bundle, so the chart now
  # serves the same self-harm disclosures the clinician surface does — and it
  # must not serve them on weaker terms. A sibling route to the same bytes
  # under a best-effort audit is the defect the fail-closed concern exists to
  # prevent, left open on the route this PR itself opened.
  def with_broken_audit
    Lakeraven::EHR::AuditEvent.define_singleton_method(:create!) do |*|
      raise ActiveRecord::StatementInvalid, "audit down"
    end
    yield
  ensure
    Lakeraven::EHR::AuditEvent.singleton_class.send(:remove_method, :create!)
  end

  SELF_HARM_ITEM_TEXT = "better off dead"
  DISCLOSING_ANSWER_CODE = "LA6571-9" # "Nearly every day"

  test "the FHIR chart serves nothing when its audit cannot be written" do
    seed_screening

    with_broken_audit { get "/patients/1.json", headers: @headers }

    assert_response :service_unavailable
    assert_no_match(/#{SELF_HARM_ITEM_TEXT}/i, response.body)
    assert_no_match(/#{DISCLOSING_ANSWER_CODE}/, response.body)
    assert_equal "application/fhir+json", response.media_type,
                 "a FHIR caller gets a FHIR refusal"
  end

  test "the HTML chart serves nothing when its audit cannot be written" do
    seed_screening

    with_broken_audit { get "/patients/1", headers: @headers }

    assert_response :service_unavailable
    assert_no_match(/Alice Anderson/, response.body)
  end

  test "a chart read that IS recorded still serves" do
    seed_screening

    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      get "/patients/1.json", headers: @headers
    end

    assert_response :ok
  end

  # -- Authorization: patient context ------------------------------------------

  test "patient-scoped token bound to a DIFFERENT patient -> 403" do
    token = token_with(scopes: "patient/*.read", resource_owner_id: 2)
    get "/patients/1.json", headers: bearer(token)

    assert_response :forbidden
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  test "mixed-scope token (patient + system) bound to a DIFFERENT patient -> 403" do
    # ANY patient/ scope binds the token to its patient compartment; a broader
    # system/ scope on the same token must not bypass the binding
    # (independent security review finding).
    token = token_with(scopes: "patient/*.read system/*.read", resource_owner_id: 2)
    get "/patients/1.json", headers: bearer(token)

    assert_response :forbidden
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  test "patient-scoped token bound to THIS patient -> 200" do
    token = token_with(scopes: "patient/*.read", resource_owner_id: 1)
    get "/patients/1.json", headers: bearer(token)

    assert_response :ok
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  # -- Audit -------------------------------------------------------------------

  # The chart is a patient-centric aggregate, so its reference is the patient —
  # and it must be a reference that AGREES with itself. Pinned on a second
  # audited surface because the ordering that produced `QuestionnaireResponse/1`
  # for screening 100 lives in shared code.
  test "the chart audit reference names the patient it served" do
    Lakeraven::EHR::AuditEvent.delete_all

    get "/patients/1.json", headers: @headers

    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_equal "Patient", event.entity_type
    assert_equal "1", event.entity_identifier
    assert_equal "Patient/1", event.to_fhir[:entity].first.dig(:what, :reference)
  end

  test "successful access records an AuditEvent" do
    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      get "/patients/1.json", headers: @headers
    end
    assert_response :ok
  end

  test "demo-bypass access still records an AuditEvent with the demo-bypass actor" do
    # Demo bypass can never activate in the test env (development? guard), so
    # force ChartsController#demo_bypass? on for this one request to exercise
    # the audit path (independent security review finding: bypass requests
    # must not be invisible to the audit log).
    with_demo_bypass_forced do
      assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
        get "/patients/1.json" # no token at all
      end
    end

    assert_response :ok
    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_equal "Service", event.agent_who_type
    assert_equal "demo-bypass", event.agent_who_identifier
    assert_equal "Patient", event.entity_type
    assert_equal "1", event.entity_identifier
  end

  def with_demo_bypass_forced
    Lakeraven::EHR::ChartsController.class_eval do
      alias_method :__real_demo_bypass?, :demo_bypass?
      def demo_bypass? = true
    end
    yield
  ensure
    Lakeraven::EHR::ChartsController.class_eval do
      alias_method :demo_bypass?, :__real_demo_bypass?
      remove_method :__real_demo_bypass?
    end
  end

  # -- Dev-only demo bypass is impossible in test ------------------------------

  test "demo bypass does NOT apply in the test environment" do
    ENV["CHART_DEMO_OPEN"] = "1"
    get "/patients/1.json" # no token

    assert_response :unauthorized
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  ensure
    ENV.delete("CHART_DEMO_OPEN")
  end

  test "demo bypass requires the mock-RPC flag even in development" do
    original_env = Rails.env
    ENV["CHART_DEMO_OPEN"] = "1"
    ENV.delete("SPIKE_MOCK_RPC")
    Rails.env = "development"

    refute Lakeraven::EHR::ChartsController.new.send(:demo_bypass?),
      "bypass must stay off without the synthetic mock backend"

    ENV["SPIKE_MOCK_RPC"] = "1"
    assert Lakeraven::EHR::ChartsController.new.send(:demo_bypass?)
  ensure
    Rails.env = original_env
    ENV.delete("CHART_DEMO_OPEN")
    ENV.delete("SPIKE_MOCK_RPC")
  end

  # -- Not found (still an OperationOutcome, once authenticated) ----------------

  test "unknown patient returns 404 as OperationOutcome for FHIR requests" do
    get "/patients/99999.json", headers: @headers

    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-found", body["issue"].first["code"]
  end
end
