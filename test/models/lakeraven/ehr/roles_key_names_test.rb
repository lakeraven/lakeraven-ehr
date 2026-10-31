# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Every name the key table asks RPMS about is a SECURITY KEY (#19.1) on the
    # pinned build (#578). The list is the build's own, taken from the rpms-diffs
    # config export; see the fixture's header for where and how to regenerate it.
    # A name RPMS does not have can never be held, so it grants nothing and hides
    # a decision nobody made: 12 of the 13 names this table used to hold were
    # like that.
    class RolesKeyNamesTest < ActiveSupport::TestCase
      KEY_LISTS = Dir[File.expand_path("../../../fixtures/security_keys/*.txt", __dir__)]

      test "exactly one pinned build key list is checked in" do
        assert_equal 1, KEY_LISTS.size, KEY_LISTS.inspect
      end

      test "every name in Roles::KEY_NAMES is a SECURITY KEY on the pinned build" do
        on_build = File.readlines(KEY_LISTS.first, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.to_set
        build = File.basename(KEY_LISTS.first, ".txt")

        missing = Roles::KEY_NAMES.values.reject { |name| on_build.include?(name) }
        assert_empty missing, "not SECURITY KEYs on #{build}: #{missing.join(', ')}"
      end

      test "every key the scope table grants on is a key the sign-on asks about" do
        assert_empty SessionScopePolicy::KEY_SCOPES.keys - Roles::KEY_NAMES.keys
      end
    end
  end
end
