# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class OrganizationGatewayTest < ActiveSupport::TestCase
      test "find returns organization data for known IEN" do
        org = OrganizationGateway.find(1)

        refute_nil org, "Should find seeded organization"
        name = org.respond_to?(:name) ? org.name : org[:name]
        assert_equal "Alaska Native Medical Center", name
      end

      test "find returns nil for non-existent organization" do
        org = OrganizationGateway.find(999_999)

        assert_nil org
      end

      test "find returns nil for blank IEN" do
        assert_nil OrganizationGateway.find(nil)
        assert_nil OrganizationGateway.find("")
      end
    end
  end
end
