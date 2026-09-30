# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TenantTest < ActiveSupport::TestCase
      test "Tenant is a first-class record representing the covered entity" do
        tenant = Tenant.new(name: "Example Covered Entity")
        assert tenant.valid?
      end

      test "Tenant holds approved instance and division pairs, not derived from deployment" do
        tenant = Tenant.new(name: "Example Covered Entity")
        tenant.approved_instances.build(instance_identifier: "config-assigned-id", division_ien: "123")
        assert tenant.valid?
      end
    end
  end
end
