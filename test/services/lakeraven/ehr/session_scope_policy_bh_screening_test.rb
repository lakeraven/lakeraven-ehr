# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Issue #526: QuestionnaireResponse scopes belong on the BH keys only.
    class SessionScopePolicyBhScreeningTest < ActiveSupport::TestCase
      QR_SCOPE = "user/QuestionnaireResponse.cruds"
      BH_KEYS = %i[behavioral_health_user behavioral_health_manager].freeze
      CHART_OPTION = "CIAV VUECENTRIC"

      test "behavioral_health_user grants exactly QuestionnaireResponse read and write" do
        assert_equal [ QR_SCOPE ],
                     SessionScopePolicy.scopes_for(security_keys: [ :behavioral_health_user ])
      end

      test "behavioral_health_manager grants exactly QuestionnaireResponse read and write" do
        assert_equal [ QR_SCOPE ],
                     SessionScopePolicy.scopes_for(security_keys: [ :behavioral_health_manager ])
      end

      test "no other KEY_SCOPES key alone grants a QuestionnaireResponse scope" do
        (SessionScopePolicy::KEY_SCOPES.keys - BH_KEYS).each do |key|
          scopes = SessionScopePolicy.scopes_for(security_keys: [ key ])
          assert_empty scopes.grep(/\Auser\/QuestionnaireResponse\./),
                       "expected #{key} to grant no QuestionnaireResponse scope, got #{scopes.inspect}"
        end
      end

      test "no OPTION_SCOPES option alone grants a QuestionnaireResponse scope" do
        SessionScopePolicy::OPTION_SCOPES.each_key do |option|
          scopes = SessionScopePolicy.scopes_for(security_keys: [], options: [ option ])
          assert_empty scopes.grep(/\Auser\/QuestionnaireResponse\./),
                       "expected option #{option.inspect} to grant no QuestionnaireResponse scope"
        end
      end

      test "no Roles key symbol outside the two BH keys grants QuestionnaireResponse scope" do
        (Roles::KEY_NAMES.keys - BH_KEYS).each do |key|
          scopes = SessionScopePolicy.scopes_for(security_keys: [ key ])
          assert_empty scopes.grep(/\Auser\/QuestionnaireResponse\./),
                       "expected #{key} to grant no QuestionnaireResponse scope"
        end
      end

      test "every non-BH key plus every option together still grants no QuestionnaireResponse scope" do
        keys = SessionScopePolicy::KEY_SCOPES.keys - BH_KEYS
        options = SessionScopePolicy::OPTION_SCOPES.keys
        scopes = SessionScopePolicy.scopes_for(security_keys: keys, options: options)
        assert_empty scopes.grep(/\Auser\/QuestionnaireResponse\./)
      end

      test "the chart option grants no write scope on any type" do
        chart_only = SessionScopePolicy.scopes_for(security_keys: [], options: [ CHART_OPTION ])
        assert_empty chart_only.grep(/\.c|\.u|\.d/)
      end

      test "absence of keys and options grants nothing" do
        assert_empty SessionScopePolicy.scopes_for(security_keys: [], options: [])
      end

      test "an unknown key symbol grants nothing" do
        assert_empty SessionScopePolicy.scopes_for(security_keys: [ :bh_provider ])
      end

      test "raw RPMS key strings are not a policy input path" do
        assert_empty SessionScopePolicy.scopes_for(security_keys: [ "AMHZMENU", "AMHZMGR" ])
      end

      test "symbolized RPMS key names grant QuestionnaireResponse through the BH symbols" do
        assert_equal [ QR_SCOPE ],
                     SessionScopePolicy.scopes_for(security_keys: Roles.symbolize_keys(%w[AMHZMENU]))
        assert_equal [ QR_SCOPE ],
                     SessionScopePolicy.scopes_for(security_keys: Roles.symbolize_keys(%w[AMHZMGR]))
      end

      test "adding the chart option to a BH key does not widen beyond QuestionnaireResponse" do
        chart_only = SessionScopePolicy.scopes_for(security_keys: [], options: [ CHART_OPTION ])
        combined = SessionScopePolicy.scopes_for(security_keys: [ :behavioral_health_user ], options: [ CHART_OPTION ])
        assert_equal [ QR_SCOPE ], combined - chart_only
      end

      test "all_scopes includes QuestionnaireResponse read and write" do
        assert_includes SessionScopePolicy.all_scopes, QR_SCOPE
      end

      test "BEHAVIORAL_HEALTH_TYPES is exactly QuestionnaireResponse" do
        assert_equal %w[QuestionnaireResponse], SessionScopePolicy::BEHAVIORAL_HEALTH_TYPES
      end
    end
  end
end
