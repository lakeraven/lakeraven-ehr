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
  end

  def refute_backend_message_in_body!(body, message = BACKEND_PROBE_MESSAGE)
    refute_includes body, message
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
    keyed[rpc_name][dfn.to_s] = [
      { ien: 901, allergen: allergen, reaction: SYNTHETIC_SYMPTOM, severity: "moderate" }
    ]
    client.instance_variable_set(:@keyed_collections, keyed)
  end
end
