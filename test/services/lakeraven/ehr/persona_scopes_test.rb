# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/demo_persona_keys"

module Lakeraven
  module EHR
    # What each demo persona may do, from the SECURITY KEYs the build gives it
    # (rpms-ops SEEDPERS, from the analyst's profiles). Keys outside the table
    # (PROVIDER, AGZMENU) grant nothing in the EHR. No RPC: the key sets are
    # fixed here, as the build files them.
    class PersonaScopesTest < ActiveSupport::TestCase
      CHART = %w[Patient Observation Condition MedicationRequest].map { |type| "user/#{type}.rs" }.freeze

      PERSONA_KEYS = DemoPersonaKeys::BY_PERSONA

      def scopes(persona)
        SessionScopePolicy.scopes_for(security_keys: Roles.symbolize_keys(PERSONA_KEYS.fetch(persona)))
      end

      test "the physician, nurse and medical assistant can read the chart" do
        %w[PROFILE,MD PROFILE,RN PROFILE,MA].each do |persona|
          CHART.each { |scope| assert_includes scopes(persona), scope, persona }
        end
      end

      test "the physician reads referrals; only an RCIS supervisor or manager writes them" do
        assert_includes scopes("PROFILE,MD"), "user/ServiceRequest.rs"
        refute scopes("PROFILE,MD").any? { |scope| scope.start_with?("user/ServiceRequest.c") }
      end

      test "the registration clerk gets no scope: AGZMENU is not in the EHR's table" do
        assert_empty scopes("PROFILE,REG")
      end

      test "the scheduler books and reads encounters and locations, and cannot read the chart" do
        assert_equal [ "user/Encounter.cruds", "user/Location.rs" ], scopes("PROFILE,SCHED")
      end

      test "no persona can approve referrals" do
        PERSONA_KEYS.each_key do |persona|
          user = CurrentUser.new(duz: "1", name: persona, user_type: "provider",
                                 security_keys: Roles.symbolize_keys(PERSONA_KEYS.fetch(persona)))
          refute user.can_approve_chs?, persona
        end
      end
    end
  end
end
