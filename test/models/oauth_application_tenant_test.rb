# frozen_string_literal: true

require "test_helper"

class OauthApplicationTenantTest < ActiveSupport::TestCase
  test "organization_id is an immutable foreign key to Tenant" do
    tenant = Lakeraven::EHR::Tenant.create!(name: "Test Tenant")
    app = Doorkeeper::Application.create!(
      name: "Test App",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      organization_id: tenant.id
    )

    assert_equal tenant.id.to_s, app.organization_id.to_s

    # Immutability check
    other_tenant = Lakeraven::EHR::Tenant.create!(name: "Other Tenant")
    app.organization_id = other_tenant.id

    assert_not app.valid?, "organization_id must be immutable after creation"
    assert_includes app.errors[:organization_id], "cannot be changed"
  end
end
