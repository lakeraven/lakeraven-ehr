# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/demo_persona_keys"

module Lakeraven
  module EHR
    # The capabilities each demo persona holds, from the keys the build gives it
    # (DemoPersonaKeys, rpms-ops SEEDPERS), read through Roles' symbolic names as
    # sign-on reads them.
    class CapabilitiesTest < ActiveSupport::TestCase
      def for_persona(persona) = Capabilities.for(Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA.fetch(persona)))

      test "each demo persona holds exactly the capabilities of its keys" do
        assert_equal %w[registration.search registration.view patient.register], for_persona("PROFILE,REG")
        assert_equal %w[registration.view scheduling.open], for_persona("PROFILE,SCHED")
        %w[PROFILE,MD PROFILE,RN PROFILE,MA].each { |clinician| assert_empty for_persona(clinician), clinician }
      end

      test "a deny key takes the capability away, as BPRM's AGZVIEWONLY does registering" do
        refute Capabilities.allows?(%i[registration_menu registration_view_only], "patient.register")
        assert Capabilities.allows?(%i[registration_menu registration_view_only], "registration.search")
      end

      test "a scheduling supervisor supervises, and a scheduler does not" do
        assert Capabilities.allows?(%w[scheduling_supervisor], "scheduling.supervise")
        refute Capabilities.allows?(%w[scheduling_user], "scheduling.supervise")
      end

      test "no keys, unknown keys and programmer mode grant nothing" do
        assert_empty Capabilities.for([])
        assert_empty Capabilities.for(nil)
        assert_empty Capabilities.for(Roles.symbolize_keys(%w[XUPROG XUPROGMODE SOME_LOCAL_KEY]))
      end

      test "an unknown capability name raises instead of refusing or allowing" do
        assert_raises(ArgumentError) { Capabilities.allows?(%i[registration_menu], "registration.serach") }
      end

      test "every rule names keys the app knows" do
        Capabilities::TABLE.each do |name, rule|
          (rule.any + rule.deny).each { |key| assert Roles::KEY_NAMES.key?(key), "#{name} names #{key}, not in Roles::KEY_NAMES" }
        end
      end
    end
  end
end
