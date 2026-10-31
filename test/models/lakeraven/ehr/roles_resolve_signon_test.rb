# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RolesResolveSignonTest < ActiveSupport::TestCase
      test "resolve_signon with nil security_keys fails closed like gem UserRoles.resolve" do
        assert_raises(NoMethodError, ArgumentError) do
          Roles.resolve_signon(user_type: "provider", security_keys: nil)
        end
      end

      test "resolve_signon treats Hash security_keys like gem include? on keys" do
        assert_equal "case_manager",
          Roles.resolve_signon(user_type: "provider", security_keys: { referrals_manager: true })
      end
    end
  end
end
