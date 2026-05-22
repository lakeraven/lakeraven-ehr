# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncounterLifecycleServiceTest < ActiveSupport::TestCase
      # FakeGateway — a clean test double accepting a fixed return value (or
      # a Proc for argument capture). Used via constructor injection on
      # EncounterLifecycleService so we never mutate the production gateway
      # classes.
      class FakeGateway
        attr_reader :calls

        def initialize(method_name, return_value)
          @method_name = method_name
          @return_value = return_value
          @calls = []
          fake = self
          define_singleton_method(method_name) do |*args, **kwargs|
            fake.calls << { args: args, kwargs: kwargs }
            fake.instance_variable_get(:@return_value).respond_to?(:call) ?
              fake.instance_variable_get(:@return_value).call(*args, **kwargs) :
              fake.instance_variable_get(:@return_value)
          end
        end
      end

      setup do
        @dfn = 26664
        @visit_ien = 2090061
        @encounter = {
          visit_ien: @visit_ien, patient_dfn: @dfn,
          location: "PS CLINICS", provider: "SAND,ASH", status: "A",
          missing_components: [
            { component: "POV", message: "Visit has no note" },
            { component: "E&M", message: "Visit has no note" }
          ]
        }
        @brief = { name: "TESTPATIENT,FIRST", dob: Date.new(1986, 7, 1), sex: "F", mrn: "120305",
                   age: 39, allergy_flag: true, ad_flag: false, primary_provider: "PROVIDER,DEFAULT" }
        @vitals = [ { type: "TMP", value: 98 }, { type: "BP", value: "120/80" } ]
        @problems = [ { ien: 1, description: "Hypertension", icd_code: "I10" } ]
        @allergies = [ { allergen: "PENICILLIN", reaction: "Hives", severity: "Severe" } ]
        @reminders = [ { id: 1, name: "Annual physical due", status: :due } ]

        @enc_gw = FakeGateway.new(:open, @encounter)
        @pt_gw  = FakeGateway.new(:brief_header, @brief)
        @obs_gw = FakeGateway.new(:for_patient, @vitals)
        @cond_gw = FakeGateway.new(:for_patient, @problems)
        @allerg_gw = FakeGateway.new(:for_patient, @allergies)
        @rem_gw = FakeGateway.new(:for_visit, @reminders)
      end

      def build_service(requester: nil, **overrides)
        gateways = {
          encounter_gateway: @enc_gw, patient_gateway: @pt_gw,
          observation_gateway: @obs_gw, condition_gateway: @cond_gw,
          allergy_gateway: @allerg_gw, reminders_gateway: @rem_gw
        }.merge(overrides)
        EncounterLifecycleService.new(@dfn, @visit_ien, requester: requester, **gateways)
      end

      # === Happy path: full hydration including reminders ===

      test "open hydrates encounter + brief_header + vitals + problems + allergies + reminders in one call" do
        result = build_service.open
        assert result.success?, "Expected success; got #{result.error.inspect}"
        ctx = result.context
        assert_equal "PS CLINICS", ctx[:encounter][:location]
        assert_equal "TESTPATIENT,FIRST", ctx[:brief_header][:name]
        assert_equal 2, ctx[:vitals].length
        assert_equal "Hypertension", ctx[:problems].first[:description]
        assert_equal 1, ctx[:allergies].length
        assert_equal "PENICILLIN", ctx[:allergies].first[:allergen]
        assert_equal 1, ctx[:reminders].length
        assert_equal "Annual physical due", ctx[:reminders].first[:name]
        # FakeGateway doesn't expose default_provider, so reminders_available?
        # defaults to true → :ok status.
        assert_equal :ok, ctx[:reminders_status]
      end

      test "open reports reminders_status :rpc_unavailable when the gateway has no provider" do
        # Use the real RemindersGateway class — which exposes default_provider
        # and returns nil when RpmsRpc::Reminders is not present.
        result = build_service(reminders_gateway: RemindersGateway).open
        assert result.success?
        # If the rpms-rpc gem hasn't shipped the Reminders API, the gateway's
        # default_provider is nil. If it has shipped, this test asserts :ok.
        expected = RemindersGateway.default_provider.nil? ? :rpc_unavailable : :ok
        assert_equal expected, result.context[:reminders_status]
      end

      test "open forwards dfn and visit_ien to each gateway" do
        build_service.open
        assert_equal [ @dfn, @visit_ien ], @enc_gw.calls.first[:args]
        assert_equal [ @dfn ], @pt_gw.calls.first[:args]
        assert_equal [ @dfn ], @obs_gw.calls.first[:args]
        assert_equal [ @dfn ], @cond_gw.calls.first[:args]
        assert_equal [ @dfn ], @allerg_gw.calls.first[:args]
        assert_equal [ @dfn, @visit_ien ], @rem_gw.calls.first[:args]
      end

      # === Failure modes ===

      test "open returns :not_found when encounter gateway returns nil" do
        nil_enc = FakeGateway.new(:open, nil)
        result = build_service(encounter_gateway: nil_enc).open
        refute result.success?
        assert_equal :not_found, result.error
      end

      test "open returns :invalid_input when visit_ien is missing" do
        result = EncounterLifecycleService.new(@dfn, nil).open
        refute result.success?
        assert_equal :invalid_input, result.error
      end

      test "open returns :invalid_input when dfn is missing" do
        result = EncounterLifecycleService.new(nil, @visit_ien).open
        refute result.success?
        assert_equal :invalid_input, result.error
      end

      # === Permission gate ===

      test "open returns :permission_denied when requester lacks :view_patients capability" do
        requester = Object.new
        def requester.can?(_perm); false; end

        result = build_service(requester: requester).open
        refute result.success?
        assert_equal :permission_denied, result.error
      end

      test "open succeeds when requester has :view_patients capability" do
        requester = Object.new
        def requester.can?(perm); perm == :view_patients; end

        result = build_service(requester: requester).open
        assert result.success?
      end

      # === Hydration failure surfacing (no more silent swallowing) ===

      test "open raises when a hydration gateway raises (no silent swallow)" do
        flaky = FakeGateway.new(:for_patient, ->(*) { raise "rpc timeout" })
        error = assert_raises(RuntimeError) { build_service(observation_gateway: flaky).open }
        assert_equal "rpc timeout", error.message
      end

      # === brief_header nil tolerance is intentional ===

      test "open succeeds with brief_header: nil so chart can render without banner" do
        nil_pt = FakeGateway.new(:brief_header, nil)
        result = build_service(patient_gateway: nil_pt).open
        assert result.success?
        assert_nil result.context[:brief_header]
      end

      # === Default reminders gateway returns [] safely when RPC primitive isn't ready ===

      test "default RemindersGateway returns empty array when underlying RPC not implemented" do
        skip "real RpmsRpc::Reminders shipped" if RemindersGateway.default_provider
        result = RemindersGateway.for_visit(1, 100)
        assert_equal [], result
      end
    end
  end
end
