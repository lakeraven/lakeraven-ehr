# frozen_string_literal: true

module Lakeraven
  module EHR
    # Tenancy enforcement for every request — ADR 0007.
    #
    # Included in ApplicationController rather than declared per controller,
    # because a tenancy boundary that each new FHIR surface has to remember to
    # opt into is the same shape of defect as lakeraven-ehr#553 itself: a
    # binding recorded in one place and consulted nowhere. PatientCompartment
    # is declared per action because naming a patient is a usability rule that
    # varies by surface; a tenant is not.
    module TenantBoundary
      extend ActiveSupport::Concern

      included do
        before_action :enforce_tenant_binding!
      end

      private

      # FAIL CLOSED on a binding that does not resolve. A client whose
      # organization_id names a tenant we do not have is refused rather than
      # served from whatever connection happens to be default.
      #
      # A BLANK organization_id is deliberately not refused here. That is the
      # mint-time gate's job (BackendServicesController refuses to issue a
      # system/ token without a binding), and browser sessions are not bound to
      # an application at all. Refusing blank here would be enforcing a rule
      # this surface does not own.
      def enforce_tenant_binding!
        return if bound_tenant_identifier.blank?
        return if bound_tenant.present?

        render_unknown_tenant
      end

      # Refuse a locally held row that belongs to another tenant.
      #
      # Returns 403 rather than filtering the row into a 404. That is the
      # step-0 spec's choice, and it is the weaker of the two on information
      # disclosure: a 403 confirms the row EXISTS while refusing it, where a
      # scoped query would deny its existence. Kept because the spec pins it;
      # noted because a cross-tenant probe can still enumerate ids.
      #
      # A row with a BLANK tenant_identifier is not refused: every row written
      # before tenancy existed has one, and treating those as foreign would
      # deny a tenant its own history.
      def authorize_tenant_row!(record)
        return true if record.nil?
        return true if bound_tenant_identifier.blank?

        row_tenant = record.tenant_identifier
        return true if row_tenant.blank?
        return true if row_tenant.to_s == bound_tenant_identifier.to_s

        render_foreign_tenant_row
        false
      end

      def render_foreign_tenant_row
        render_operation_outcome(
          status: :forbidden,
          severity: "error",
          code: "forbidden",
          diagnostics: "Resource belongs to another tenant"
        )
      end

      def bound_tenant_identifier
        doorkeeper_token&.application&.organization_id
      end

      def bound_tenant
        return @bound_tenant if defined?(@bound_tenant)

        @bound_tenant = Tenant.find_by(id: bound_tenant_identifier)
      end

      def render_unknown_tenant
        render_operation_outcome(
          status: :forbidden,
          severity: "error",
          code: "forbidden",
          diagnostics: "Client is not bound to a known tenant"
        )
      end
    end
  end
end
