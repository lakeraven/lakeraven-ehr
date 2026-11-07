# frozen_string_literal: true

require_relative "patient_banner_test_helper"

# Shared helpers for allergy write specification (#644).
module AllergyWriteTestHelper
  include PatientBannerTestHelper

  MOUNT = PatientBannerTestHelper::MOUNT
  DUZ = PatientBannerTestHelper::DUZ

  WRITE_SCOPES = [
    "user/Patient.read",
    "user/AllergyIntolerance.read",
    "user/AllergyIntolerance.write",
    "user/Condition.read",
    "user/MedicationRequest.read",
    "user/Observation.read",
    "user/QuestionnaireResponse.read",
    "user/QuestionnaireResponse.write"
  ].join(" ")

  READ_SCOPES = WRITE_SCOPES.gsub("user/AllergyIntolerance.write", "").squeeze(" ")

  SYNTHETIC_AGENT = "SYNTHETIC-AGENT-A"
  SYNTHETIC_COMMENT = "SYNTHETIC-COMMENT-LINE"
  SYNTHETIC_SYMPTOM = "SYNTHETIC-SYMPTOM-RASH"
  SYNTHETIC_NINTH_COMMENT = "SYNTHETIC-NINTH"
  SYNTHETIC_TENTH_COMMENT = "SYNTHETIC-TENTH"
  SYNTHETIC_EIGHTH_COMMENT = "SYNTHETIC-EIGHTH"
  SYNTHETIC_EIGHTH_SYMPTOM = "SYNTHETIC-SYMPTOM-EIGHTH"

  # Valid wire-shaped attrs for RpmsRpc::Allergy.save (originator is set by the
  # server from the clinician DUZ, not trusted from the form).
  def valid_synthetic_allergy_attrs(originator: DUZ)
    {
      agent: SYNTHETIC_AGENT,
      agent_pointer: "125;PSNDF(50.6,",
      type: "D",
      nature: "A",
      originator: originator,
      originated_at: "3261015.1045",
      observed_or_historical: "o",
      symptoms: [ { ien: "10", text: SYNTHETIC_SYMPTOM, date: "3261015" } ],
      comments: [ SYNTHETIC_COMMENT ],
      reaction_date: "3261015",
      severity: "2"
    }
  end

  def allergy_form_params(extra = {})
    { allergy: valid_synthetic_allergy_attrs.merge(extra) }
  end

  # Rails indexed form encoding (allergy[symptoms][0][text]=...) arrives as
  # a Hash keyed by index strings, not as an Array.
  def indexed_allergy_form_params(symptom_text: SYNTHETIC_SYMPTOM, comment: SYNTHETIC_COMMENT, extra: {})
    base = valid_synthetic_allergy_attrs.except(:symptoms, :comments, :originator)
    {
      allergy: base.merge(
        symptoms: { "0" => { ien: "10", text: symptom_text, date: "3261015" } },
        comments: { "0" => comment }
      ).merge(extra)
    }
  end

  BACKEND_PROBE_MESSAGE = "BACKEND-PROBE-SECRET-644"

  # Probe audit insert succeeds; the post-action audit row fails (#644).
  def with_audit_create_failing_after_probe
    calls = 0
    audit_model = Lakeraven::EHR::AuditEvent
    original = audit_model.method(:create!)
    audit_model.define_singleton_method(:create!) do |*args, **kwargs|
      calls += 1
      raise ActiveRecord::StatementInvalid, "audit down" if calls > 1

      original.call(*args, **kwargs)
    end
    yield
  ensure
    audit_model.singleton_class.send(:remove_method, :create!)
  end

  def assert_error_log_without_clinical_text!(logs)
    assert_match(/\bERROR\b/i, logs, "expected an error-level log line")
    refute_includes logs, SYNTHETIC_AGENT
    refute_includes logs, SYNTHETIC_COMMENT
    refute_includes logs, SYNTHETIC_SYMPTOM
    refute_includes logs, SYNTHETIC_NINTH_COMMENT
    refute_includes logs, SYNTHETIC_TENTH_COMMENT
    refute_includes logs, SYNTHETIC_EIGHTH_COMMENT
    refute_includes logs, SYNTHETIC_EIGHTH_SYMPTOM
  end

  # Round-3: RPC may have run but outcome is unknown and the post-action audit failed.
  def assert_unknown_outcome_audit_failure_503!(body = response.body)
    assert_response :service_unavailable
    assert_match(/may have been recorded|outcome is unknown/i, body)
    assert_match(/audit/i, body)
    assert_match(/check the chart/i, body)
    refute_match(/not completed|not saved|left unchanged/i, body)
  end

  def assert_nothing_written_outcome_audit_failure_503!(body = response.body)
    assert_response :service_unavailable
    assert_match(/not completed/i, body)
  end

  def refute_clinical_text_in_audit_outcome_desc!(desc)
    text = desc.to_s
    [
      SYNTHETIC_AGENT, SYNTHETIC_COMMENT, SYNTHETIC_SYMPTOM,
      SYNTHETIC_NINTH_COMMENT, SYNTHETIC_TENTH_COMMENT,
      SYNTHETIC_EIGHTH_COMMENT, SYNTHETIC_EIGHTH_SYMPTOM
    ].each do |fragment|
      refute_includes text, fragment
    end
  end

  def assert_audit_unknown_write_outcome!(event, error_symbol)
    assert_equal "8", event.outcome
    desc = event.outcome_desc.to_s
    assert_match(/outcome unknown/i, desc)
    assert_includes desc, error_symbol.to_s
    refute_clinical_text_in_audit_outcome_desc!(desc)
  end

  def assert_audit_named_refusal_outcome!(event, error_symbol)
    assert_equal "4", event.outcome
    assert_includes event.outcome_desc.to_s, error_symbol.to_s
    refute_clinical_text_in_audit_outcome_desc!(event.outcome_desc)
  end

  def gateway_attrs_list(attrs, key)
    list = attrs[key] || attrs[key.to_s]
    list
  end

  def refute_backend_message_in_body!(body = response.body, message = BACKEND_PROBE_MESSAGE)
    refute_includes body, message
  end

  # Scalar allergy fields for raw form posts (no symptoms, comments, or originator).
  def base_allergy_scalar_attrs
    valid_synthetic_allergy_attrs.except(:symptoms, :comments, :originator)
  end

  def allergy_scalar_query_string(except: [], merge: {})
    attrs = base_allergy_scalar_attrs.except(*except).merge(merge)
    attrs.map { |k, v| "allergy[#{k}]=#{CGI.escape(v.to_s)}" }.join("&")
  end

  def post_raw_allergy_form(url, body_query_string, tracker: @tracker)
    with_tracking_allergy_gateway(tracker) do
      post url,
           params: "#{body_query_string}&authenticity_token=#{CGI.escape(csrf_token)}",
           headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end
  end

  def post_allergy_json(url, allergy_hash, tracker: @tracker)
    with_tracking_allergy_gateway(tracker) do
      post url,
           params: { allergy: allergy_hash }.to_json,
           headers: { "CONTENT_TYPE" => "application/json", "X-CSRF-Token" => csrf_token }
    end
  end

  def assert_strict_allergy_form_refused!
    assert_response :unprocessable_entity
    assert_match(/not saved/i, response.body)
    assert_empty @tracker.add_calls
  end

  def assert_unknown_gateway_outcome!(body = response.body)
    assert_match(/unknown|could not confirm|check the chart/i, body)
    refute_match(/was not saved|left unchanged/i, body)
  end

  def assert_named_allergy_not_saved_refusal!(pattern)
    assert_response :unprocessable_entity
    assert_match(pattern, response.body)
    assert_match(/not saved/i, response.body)
  end

  # Query string matching new.html.erb when optional scalars and comment are blank.
  def shipped_allergy_form_empty_optionals_query_string
    required = {
      agent: SYNTHETIC_AGENT,
      agent_pointer: "125;PSNDF(50.6,",
      type: "D",
      nature: "A",
      originated_at: "3261015.1045",
      observed_or_historical: "o",
      reaction_date: "",
      severity: ""
    }
    parts = required.map { |k, v| "allergy[#{k}]=#{CGI.escape(v.to_s)}" }
    parts += [
      "allergy[symptoms][][ien]=#{CGI.escape('10')}",
      "allergy[symptoms][][text]=#{CGI.escape(SYNTHETIC_SYMPTOM)}",
      "allergy[symptoms][][date]=",
      "allergy[comments][]="
    ]
    parts.join("&")
  end

  class FakeAllergyRpc
    attr_reader :save_calls, :nka_calls

    def initialize(save_returns: { success: true, note_ien: 1 },
                   nka_returns: { success: true, note_ien: nil },
                   save_raise: nil,
                   nka_raise: nil)
      @save_returns = save_returns
      @nka_returns = nka_returns
      @save_raise = save_raise
      @nka_raise = nka_raise
      @save_calls = []
      @nka_calls = []
    end

    def save(dfn, allergy)
      @save_calls << { dfn: dfn, allergy: allergy.deep_dup }
      raise @save_raise if @save_raise

      @save_returns
    end

    def no_known_allergies(dfn)
      @nka_calls << { dfn: dfn }
      raise @nka_raise if @nka_raise

      @nka_returns
    end
  end

  def with_fake_allergy_rpc(fake)
    singleton = RpmsRpc::Allergy.singleton_class
    original_save = singleton.instance_method(:save)
    original_nka = singleton.instance_method(:no_known_allergies)

    RpmsRpc::Allergy.define_singleton_method(:save) do |dfn, allergy|
      fake.save(dfn, allergy)
    end
    RpmsRpc::Allergy.define_singleton_method(:no_known_allergies) do |dfn|
      fake.no_known_allergies(dfn)
    end
    yield
  ensure
    singleton.send(:define_method, :save, original_save)
    singleton.send(:define_method, :no_known_allergies, original_nka)
  end

  class TrackingAllergyGateway
    attr_reader :add_calls, :nka_calls

    def initialize(add_returns: { success: true, note_ien: 1 },
                   nka_returns: { success: true, note_ien: nil })
      @add_returns = add_returns
      @nka_returns = nka_returns
      @add_calls = []
      @nka_calls = []
    end

    def add(dfn, attrs, clinician_duz: nil)
      @add_calls << { dfn: dfn, attrs: attrs.deep_dup, clinician_duz: clinician_duz }
      @add_returns
    end

    def record_no_known_allergies(dfn)
      @nka_calls << { dfn: dfn }
      @nka_returns
    end

    def for_patient(_dfn)
      []
    end

    def assessment(_dfn)
      { assessed: false, nka: false, allergies: [] }
    end
  end

  def with_tracking_allergy_gateway(tracker)
    gateway = Lakeraven::EHR::AllergyIntoleranceGateway
    singleton = gateway.singleton_class
    methods = %i[add record_no_known_allergies]
    originals = methods.index_with { |name| singleton.instance_method(name) if singleton.method_defined?(name) }

    gateway.define_singleton_method(:add) do |dfn, attrs, clinician_duz: nil|
      tracker.add(dfn, attrs, clinician_duz: clinician_duz)
    end
    gateway.define_singleton_method(:record_no_known_allergies) { |dfn| tracker.record_no_known_allergies(dfn) }
    yield
  ensure
    methods.each do |name|
      if originals[name]
        singleton.send(:define_method, name, originals[name])
      else
        singleton.send(:remove_method, name) if singleton.method_defined?(name)
      end
    end
  end

  def gateway_success?(result)
    return result[:success] == true if result.is_a?(Hash)

    result.respond_to?(:success?) && result.success?
  end

  def gateway_failure_reason(result)
    if result.is_a?(Hash)
      result[:error] || result[:message] || result[:reason]
    elsif result.respond_to?(:error)
      result.error
    end
  end

  def capture_rails_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    previous = Rails.logger
    Rails.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous
  end

  def seed_synthetic_allergy_row!(dfn, allergen: SYNTHETIC_AGENT)
    client = RpmsRpc.configuration.client
    mapping = RpmsRpc::DataMapper[:allergy_list]
    rpc_name = mapping.rpc_name
    keyed = (client.instance_variable_get(:@keyed_collections) || {}).dup
    keyed[rpc_name] = (keyed[rpc_name] || {}).dup
    # The line LIST^ORQQAL writes (IEN^ALLERGEN^SEVERITY^SIGNS): a Hash here is
    # no ORQQAL line, and the gem reads one as a conflicting reply (#672).
    keyed[rpc_name][dfn.to_s] = [ "901^#{allergen}^MODERATE^#{SYNTHETIC_SYMPTOM}" ]
    client.instance_variable_set(:@keyed_collections, keyed)
  end
end
