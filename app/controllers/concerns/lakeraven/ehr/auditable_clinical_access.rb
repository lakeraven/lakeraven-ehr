# frozen_string_literal: true

module Lakeraven
  module EHR
    # AuditableClinicalAccess — attach to a FHIR controller to
    # automatically create an AuditEvent for every PHI-touching
    # action. Runs as an after_action so it captures the actual
    # response status code.
    #
    # Usage:
    #
    #   class Lakeraven::EHR::PatientsController < ApplicationController
    #     include Lakeraven::EHR::SmartAuthentication
    #     include Lakeraven::EHR::AuditableClinicalAccess
    #     audit_clinical_access only: :show
    #   end
    #
    # The concern reads agent identity from the current SMART token
    # (set by SmartAuthentication#authenticate_smart_token!). Unlike
    # multi-modal apps that juggle session/user/patient sources, the
    # engine has exactly one authentication boundary: the Bearer
    # token.
    module AuditableClinicalAccess
      extend ActiveSupport::Concern

      class_methods do
        def audit_clinical_access(**options)
          after_action :record_clinical_access_audit, **options
        end
      end

      private

      def record_clinical_access_audit
        AuditEvent.create!(
          event_type: "rest",
          action: audit_action_from_http_method,
          outcome: audit_outcome_from_response_status,
          tenant_identifier: Current.tenant_identifier,
          facility_identifier: Current.facility_identifier,
          agent_who_type: "Application",
          agent_who_identifier: audit_agent_identifier,
          agent_network_address: request.remote_ip,
          entity_type: audit_entity_type,
          entity_identifier: params[:identifier].to_s.presence,
          source_observer: "lakeraven-ehr"
        )
      rescue => e
        # Audit failures must not break the request. Log and move on;
        # a monitoring alert on the log line catches persistent
        # problems without pushing an ORM error back at the client.
        Rails.logger.error("AuditableClinicalAccess: #{e.class}: #{e.message}")
      end

      # Map HTTP method to FHIR CRUDE action code.
      def audit_action_from_http_method
        case request.request_method
        when "POST"   then "C"
        when "PUT"    then "U"
        when "PATCH"  then "U"
        when "DELETE" then "D"
        else "R"
        end
      end

      # Map response status to FHIR outcome code.
      def audit_outcome_from_response_status
        case response.status
        when 200..399 then "0"   # Success
        when 400..499 then "4"   # Minor Failure
        else "8"                 # Serious Failure
        end
      end

      # Opaque identifier of the OAuth client that made the request.
      # Never a user/staff DUZ — the engine only sees SMART tokens.
      def audit_agent_identifier
        return "unknown" unless respond_to?(:current_token, true) && current_token
        current_token.application&.uid.to_s.presence || "unknown"
      end

      # FHIR entity type derived from the controller name. Patients
      # controller → "Patient", practitioners controller →
      # "Practitioner", etc.
      def audit_entity_type
        controller_name.classify
      end
    end
  end
end
