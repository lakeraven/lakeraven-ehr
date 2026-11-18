# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/demo_persona_keys"

module Lakeraven
  module EHR
    # Who may write and sign a progress note from the chart (#1001): the holder
    # of the RPMS PROVIDER security key, and no one else.
    class ProgressNoteCapabilityTest < ActiveSupport::TestCase
      CAPABILITY = "progress_note.write"
      KEY_LIST = Dir[File.expand_path("../../../fixtures/security_keys/*.txt", __dir__)].first

      def assert_capability_defined!
        assert_includes Capabilities::NAMES, CAPABILITY
      end

      test "the sign-on asks RPMS about the PROVIDER key, by the name provider" do
        assert_equal "PROVIDER", Roles::KEY_NAMES[:provider]
        assert_equal [ :provider ], Roles.symbolize_keys([ "PROVIDER" ])
      end

      test "PROVIDER is a SECURITY KEY on the pinned build" do
        assert_includes Roles::KEY_NAMES.values, "PROVIDER"
        assert_includes File.readlines(KEY_LIST, chomp: true), "PROVIDER"
      end

      test "progress_note.write is a capability" do
        assert_capability_defined!
        assert Capabilities::TABLE.key?(CAPABILITY)
      end

      test "the provider key meets progress_note.write" do
        assert_capability_defined!
        assert Capabilities.allows?(%i[provider], CAPABILITY)
        assert Capabilities.allows?(%w[provider], CAPABILITY), "keys as the session holds them"
        assert_includes Capabilities.for(%i[provider]), CAPABILITY
      end

      test "the provider key still meets it beside other keys" do
        assert_capability_defined!
        assert Capabilities.allows?(%i[provider orders_sign registration_view_only], CAPABILITY)
      end

      test "ordering, scheduling and registration keys do not meet progress_note.write without PROVIDER" do
        assert_capability_defined!
        %i[orders_sign orders_enter orders_release scheduling_user scheduling_supervisor scheduling_admin
           scheduling_registration registration_menu registration_manager registration_view_only].each do |key|
          refute Capabilities.allows?([ key ], CAPABILITY), "#{key} alone"
        end
        refute Capabilities.allows?(%i[orders_sign orders_enter scheduling_user registration_menu], CAPABILITY)
      end

      test "no other key the app knows meets progress_note.write" do
        assert_capability_defined!
        others = Roles::KEY_NAMES.keys - [ :provider ]
        refute Capabilities.allows?(others, CAPABILITY), "every known key but provider, held together"
        refute Capabilities.allows?([], CAPABILITY)
        refute Capabilities.allows?(nil, CAPABILITY)
      end

      test "the demo personas that hold PROVIDER may write a note, and the clerks may not" do
        assert_capability_defined!
        holds = ->(persona) { Capabilities.for(Roles.symbolize_keys(DemoPersonaKeys::BY_PERSONA.fetch(persona))) }

        assert_includes holds.call("PROFILE,MD"), CAPABILITY
        assert_includes holds.call("PROFILE,RN"), CAPABILITY
        refute_includes holds.call("PROFILE,REG"), CAPABILITY
        refute_includes holds.call("PROFILE,SCHED"), CAPABILITY
      end
    end
  end
end
