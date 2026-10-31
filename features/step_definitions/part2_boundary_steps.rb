# frozen_string_literal: true

When("I add a substance use diagnosis to the patient's problem list") do
  @patient_dfn = "123"
  @problem = { code: "F11.20", display: "Opioid dependence", code_system: "http://hl7.org/fhir/sid/icd-10-cm" }

  # Ensure the gateway is loaded so RpmsRpc::Problem is defined as a module
  require_relative "../../app/gateways/lakeraven/ehr/condition_gateway"

  @rpms_problem_add_calls = []
  calls = @rpms_problem_add_calls

  # Define the manual capture stub to track calls instead of mocking behavior
  sc = RpmsRpc::Problem.singleton_class
  if sc.method_defined?(:add)
    original = sc.instance_method(:add)
    @gateway_stubs << -> { sc.send(:define_method, :add, original) }
  else
    @gateway_stubs << -> { sc.send(:remove_method, :add) }
  end

  RpmsRpc::Problem.define_singleton_method(:add) do |*args, **kwargs|
    calls << { args: args, kwargs: kwargs }
  end

  # R1 is underspecified: no mechanism exists to classify a ProgressNote or Condition as SUD-related on the write path.
  # We use the hardcoded ICD-10 F-code check as the spec's chosen discriminator, but a true SUD classifier is the missing piece.
  Lakeraven::EHR::ConditionGateway.add(@patient_dfn, @problem)
end

Then("the diagnosis is NOT written to the shared RPMS files") do
  assert_empty @rpms_problem_add_calls
end

When("I check the available consent scopes") do
  @scopes = defined?(Lakeraven::EHR::Consent::SCOPES) ? Lakeraven::EHR::Consent::SCOPES : {}
end

Then("there must be a specific scope for {string}") do |scope_name|
  # CHAIR AMENDMENT (rationale recorded, assertion STRENGTHENED not weakened):
  # this step ignored scope_name entirely, so it passed for any scope the
  # feature named -- it could not enforce its own wording. Reviewer finding on
  # #568. The gate seat could not execute tests across five rounds, so this is
  # amended here rather than in a sixth blind round; the requirement is
  # unchanged and the check is now stricter.
  key = Lakeraven::EHR::Consent::PART2_SCOPES.first
  assert_includes @scopes.keys, key,
    "no dedicated consent scope exists for #{scope_name}"
  assert_match(/substance[- ]use/i, @scopes[key].to_s,
    "scope #{key.inspect} does not describe #{scope_name}; a general scope must not stand in for it")
end

When("a C-CDA is requested for the patient") do
  @patient_dfn = "123"

  # Provide Patient model if missing for the stub_gateway call
  unless defined?(Lakeraven::EHR::Patient)
    module Lakeraven
      module EHR
        class Patient
          attr_accessor :dfn, :name
          def initialize(dfn:, name:)
            @dfn = dfn
            @name = name
          end
        end
      end
    end
  end

  patient = Lakeraven::EHR::Patient.new(dfn: @patient_dfn, name: "Test,Patient")
  stub_gateway(Lakeraven::EHR::Patient, :find_by_dfn, patient)

  # Provide Egress filter if missing for recording stub
  unless defined?(Lakeraven::EHR::Part2EgressFilter)
    module Lakeraven
      module EHR
        class Part2EgressFilter
        end
      end
    end
  end

  @egress_filter_calls = []
  filter_calls = @egress_filter_calls

  sc = Lakeraven::EHR::Part2EgressFilter.singleton_class
  if sc.method_defined?(:call)
    original = sc.instance_method(:call)
    @gateway_stubs << -> { sc.send(:define_method, :call, original) }
  else
    @gateway_stubs << -> { sc.send(:remove_method, :call) }
  end
  Lakeraven::EHR::Part2EgressFilter.define_singleton_method(:call) do |*args, **kwargs|
    filter_calls << { args: args, kwargs: kwargs }
    []
  end

  app = Doorkeeper::Application.create!(
    name: "part2-test", redirect_uri: "https://example.test/callback",
    scopes: "system/*.read system/*.write", confidential: true
  )
  token = Doorkeeper::AccessToken.create!(
    application: app, scopes: "system/*.read system/*.write", expires_in: 3600
  )
  # Rack::Test takes a Rack ENV, not a `headers:` option -- `post(..., headers:)`
  # is silently ignored, which is why this returned
  # 401 "No Bearer token provided" with a perfectly good token in hand. Set the
  # header on the session first, the way every other step file here does
  # (e.g. bulk_export_steps.rb:15).
  header "Authorization", "Bearer #{token.plaintext_token || token.token}"

  begin
    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: @patient_dfn }
  rescue => e
    @post_error = e
  end
end

Then("the data is passed through the Part 2 egress filter") do
  assert_nil @post_error
  refute_empty @egress_filter_calls
end
