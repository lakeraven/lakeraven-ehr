# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TenantBoundaryTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include BrokerStubbing

      setup do
        setup_smart_auth

        # We need a Tenant model to exist for this test. Since we are only writing tests,
        # the model doesn't exist yet. We will mock or use the DB directly if needed, but
        # since we can't create the model, we'll just use the organization_id string for now.
        # If Tenant doesn't exist, `Tenant.create!` will raise NameError. This is a valid failure.
      end

      teardown do
        teardown_smart_auth
      end

      test "a system/ token bound to tenant A requesting a local resource belonging to tenant B is REFUSED" do
        # This test pins the requirement that locally held clinical rows (like AuditEvent)
        # must be scoped to the token's tenant.
        # Fails today because:
        # 1. Tenant model does not exist (NameError).
        # 2. AuditEventsController does not filter by tenant_identifier, so it would return 200 OK.

        tenant_a = Tenant.create!(name: "Tenant A")
        tenant_b = Tenant.create!(name: "Tenant B")

        @oauth_app.update!(organization_id: tenant_a.id)

        # entity_type added by the builder: the model validates its presence, so
        # without it this fixture raised RecordInvalid and the test could never
        # reach its assertions. No assertion below was changed (#553).
        event = AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          tenant_identifier: tenant_b.id.to_s
        )

        get "/lakeraven-ehr/AuditEvent/#{event.id}", headers: @headers

        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "forbidden", body["issue"].first["code"]
      end

      test "a system/ token with an unmapped/unknown tenant FAILS CLOSED on RPMS reads" do
        # This test pins the requirement that a token with an unknown/unmapped tenant
        # must be refused (fail closed) rather than proceeding on a default connection.
        # Fails today because:
        # PatientsController ignores the token's organization_id and uses the global RpmsRpc.client.
        # It will return 200 OK instead of 403 Forbidden.

        @oauth_app.update!(organization_id: "unknown-tenant-id")

        get "/lakeraven-ehr/Patient/1", headers: @headers

        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "forbidden", body["issue"].first["code"]
      end

      test "the Lakeraven::EHR::TenantBoundary concern is included in ApplicationController" do
        # This test pins the architectural decision to enforce tenancy globally via a concern
        # rather than at each FHIR controller.
        # Fails today because:
        # Lakeraven::EHR::TenantBoundary concern does not exist and is not included in ApplicationController.
        assert_includes ApplicationController.ancestors, Lakeraven::EHR::TenantBoundary
      end
    end
  end
end
