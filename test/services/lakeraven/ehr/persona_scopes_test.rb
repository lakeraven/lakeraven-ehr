# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/demo_persona_keys"

module Lakeraven
  module EHR
    # What each demo persona may do, from the SECURITY KEYs and options the build
    # gives it (rpms-ops SEEDPERS, from the analyst's profiles). The chart comes
    # from the option RPMS opens VueCentric's chart with, CIAV VUECENTRIC; what a
    # persona may change comes from its keys. No RPC: the sets are fixed here, as
    # the build files them.
    class PersonaScopesTest < ActiveSupport::TestCase
      CHART = %w[Patient Observation Condition MedicationRequest].map { |type| "user/#{type}.rs" }.freeze

      def scopes(persona)
        SessionScopePolicy.scopes_for(
          security_keys: Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA.fetch(persona)),
          options: DemoPersonaKeys::OPTIONS_BY_PERSONA.fetch(persona)
        )
      end

      test "every persona RPMS lets open VueCentric reads the chart" do
        DemoPersonaKeys::BY_PERSONA.each_key do |persona|
          CHART.each { |scope| assert_includes scopes(persona), scope, persona }
        end
      end

      test "a user RPMS does not let open VueCentric reads no chart, whatever keys they hold" do
        scopes = SessionScopePolicy.scopes_for(security_keys: Roles.symbolize_keys(%w[ORES ORELSE OREMAS]), options: [])
        CHART.each { |scope| refute_includes scopes, scope }
      end

      test "the chart option reads and writes nothing else" do
        chart_only = SessionScopePolicy.scopes_for(security_keys: [], options: [ "CIAV VUECENTRIC" ])
        refute chart_only.any? { |scope| scope.match?(/\.c|\.u|\.d/) }, chart_only.inspect
        refute_includes chart_only, "user/ServiceRequest.rs"
      end

      test "the physician reads referrals; only an RCIS supervisor or manager writes them" do
        assert_includes scopes("PROFILE,MD"), "user/ServiceRequest.rs"
        refute scopes("PROFILE,MD").any? { |scope| scope.start_with?("user/ServiceRequest.c") }
      end

      test "the registration clerk reads the chart and changes nothing" do
        refute scopes("PROFILE,REG").any? { |scope| scope.match?(/\.c|\.u|\.d/) }
      end

      test "the scheduler books encounters as well as reading the chart" do
        assert_includes scopes("PROFILE,SCHED"), "user/Encounter.cruds"
        assert_includes scopes("PROFILE,SCHED"), "user/Location.rs"
      end

      test "no persona can approve referrals" do
        DemoPersonaKeys::BY_PERSONA.each_key do |persona|
          user = CurrentUser.new(duz: "1", name: persona, user_type: "provider",
                                 security_keys: Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA.fetch(persona)))
          refute user.can_approve_chs?, persona
        end
      end
    end
  end
end
