# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class InboundServiceRequestsTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include IhsFeatureAvailabilityTestHelper

      CREATE_PATH = "/lakeraven-ehr/ServiceRequest"
      METADATA_PATH = "/lakeraven-ehr/metadata"
      REFERRAL_ID_SYSTEM = "https://snf.example.test/referrals"
      PATIENT_ID_SYSTEM = "https://example.test/mrn"
      REFERRAL_ID_VALUE = "REF-0001"
      PATIENT_MRN = "MRN-TEST-0001"
      ORGANIZATION_ID = "example-organization-inbound-test"

      setup do
        AuditEvent.delete_all
        install_oauth_client!(scopes: "system/ServiceRequest.write", organization_id: ORGANIZATION_ID)
      end

      teardown do
        delete_inbound_records_if_defined
        AuditEvent.delete_all
        teardown_restricted_backend
        teardown_smart_auth
      end

      # -- Auth -----------------------------------------------------------------

      test "POST without token returns 401" do
        post CREATE_PATH,
             params: valid_service_request_json,
             headers: { "Content-Type" => "application/fhir+json" }
        assert_response :unauthorized
      end

      test "token without ServiceRequest write scope returns 403 and stores nothing" do
        install_oauth_client!(scopes: "system/*.read", organization_id: ORGANIZATION_ID)

        assert_no_inbound_change do
          post_service_request(valid_service_request)
        end

        assert_response :forbidden
      end

      test "user-scoped ServiceRequest write returns 403 and stores nothing" do
        install_oauth_client!(scopes: "user/ServiceRequest.write", organization_id: ORGANIZATION_ID)

        assert_no_inbound_change do
          post_service_request(valid_service_request)
        end

        assert_response :forbidden
      end

      test "patient-scoped ServiceRequest write returns 403 and stores nothing" do
        install_oauth_client!(scopes: "patient/ServiceRequest.write", organization_id: ORGANIZATION_ID)

        assert_no_inbound_change do
          post_service_request(valid_service_request)
        end

        assert_response :forbidden
      end

      test "mixed system write with any patient scope returns 403 and stores nothing" do
        install_oauth_client!(
          scopes: "system/ServiceRequest.write patient/Patient.read",
          organization_id: ORGANIZATION_ID
        )

        assert_no_inbound_change do
          post_service_request(valid_service_request)
        end

        assert_response :forbidden
      end

      test "system ServiceRequest.c scope is accepted for intake create" do
        install_oauth_client!(scopes: "system/ServiceRequest.c", organization_id: ORGANIZATION_ID)

        assert_difference -> { inbound_referral_count }, 1 do
          post_service_request(valid_service_request(identifier_value: "REF-SMART-C-0001"))
        end

        assert_response :created
      end

      test "system wildcard scopes system/*.c and system/*.* are accepted for intake create" do
        %w[system/*.c system/*.*].each do |scopes|
          delete_inbound_records_if_defined
          install_oauth_client!(scopes: scopes, organization_id: ORGANIZATION_ID)

          assert_difference -> { inbound_referral_count }, 1 do
            post_service_request(valid_service_request(identifier_value: "REF-WILD-#{scopes.tr('/', '-').tr('*', 'X')}"))
          end

          assert_response :created
        end
      end

      test "system ServiceRequest.c with user Patient read scope returns 403 and stores nothing" do
        install_oauth_client!(
          scopes: "system/ServiceRequest.c user/Patient.read",
          organization_id: ORGANIZATION_ID
        )

        assert_no_inbound_change do
          post_service_request(valid_service_request(identifier_value: "REF-SMART-C-PATIENT-READ"))
        end

        assert_response :forbidden
      end

      # -- Successful intake ----------------------------------------------------

      test "valid ServiceRequest create returns 201 FHIR body and persists intake queue row" do
        payload = valid_service_request(client_submitted_id: "partner-assigned-id-ignored")
        payload["identifier"] << {
          "system" => "#{REFERRAL_ID_SYSTEM}/secondary",
          "value" => "REF-SECOND-0001"
        }

        assert_difference -> { inbound_referral_count }, 1 do
          post_service_request(payload)
        end

        assert_response :created
        assert_equal "application/fhir+json", response.media_type

        body = JSON.parse(response.body)
        assert_equal "ServiceRequest", body["resourceType"]
        assert_equal payload["status"], body["status"]
        assert_equal payload["intent"], body["intent"]
        assert_equal payload["identifier"], body["identifier"]
        assert_equal payload.dig("code", "coding"), body.dig("code", "coding")
        assert_equal payload.dig("subject", "identifier"), body.dig("subject", "identifier")

        referral = Lakeraven::EHR::InboundReferral.order(:created_at).last
        assert_equal body["id"], referral.public_id
        assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, body["id"])
        refute_equal "partner-assigned-id-ignored", body["id"]

        assert_equal "received", referral.status
        assert_equal PATIENT_ID_SYSTEM, referral.patient_identifier_system
        assert_equal PATIENT_MRN, referral.patient_identifier_value
        assert_equal @oauth_app.id, referral.oauth_application_id
        assert_equal ORGANIZATION_ID, referral.organization_id
        assert_equal payload.except("id"), referral.resource.deep_stringify_keys
        refute referral.resource.deep_stringify_keys.key?("id")

        identifiers = referral.identifiers.order(:system, :value)
        assert_equal 2, identifiers.size
        assert_equal [ REFERRAL_ID_SYSTEM, "#{REFERRAL_ID_SYSTEM}/secondary" ].sort,
                     identifiers.map(&:system).sort
      end

      # -- Idempotency ----------------------------------------------------------

      test "reposting the same payload for the same client returns 200 with the same id" do
        post_service_request(valid_service_request)
        assert_response :created
        first_id = JSON.parse(response.body)["id"]

        assert_no_inbound_change do
          post_service_request(valid_service_request)
        end

        assert_response :ok
        assert_equal first_id, JSON.parse(response.body)["id"]
      end

      test "matching identifier with changed content returns 200 and leaves stored resource unchanged" do
        original = valid_service_request(status: "active")
        post_service_request(original)
        assert_response :created
        first_body = JSON.parse(response.body)

        altered = valid_service_request(status: "draft", intent: "proposal")
        post_service_request(altered)
        assert_response :ok

        second_body = JSON.parse(response.body)
        assert_equal first_body["id"], second_body["id"]
        assert_equal "active", second_body["status"]
        assert_equal "order", second_body["intent"]

        stored = Lakeraven::EHR::InboundReferral.find_by!(public_id: first_body["id"])
        assert_equal "active", stored.resource["status"]
        assert_equal "order", stored.resource["intent"]
      end

      test "the same identifier from a different OAuth client creates a separate referral" do
        post_service_request(valid_service_request)
        assert_response :created
        first_id = JSON.parse(response.body)["id"]

        install_oauth_client!(scopes: "system/ServiceRequest.write", organization_id: "example-organization-inbound-other")

        assert_difference -> { inbound_referral_count }, 1 do
          post_service_request(valid_service_request)
        end

        assert_response :created
        refute_equal first_id, JSON.parse(response.body)["id"]
      end

      test "identifiers matching two existing referrals for one client returns 409 conflict" do
        post_service_request(valid_service_request(identifier_value: "REF-CONFLICT-A"))
        assert_response :created

        post_service_request(valid_service_request(identifier_value: "REF-CONFLICT-B"))
        assert_response :created

        dual = valid_service_request
        dual["identifier"] = [
          { "system" => REFERRAL_ID_SYSTEM, "value" => "REF-CONFLICT-A" },
          { "system" => REFERRAL_ID_SYSTEM, "value" => "REF-CONFLICT-B" }
        ]

        assert_no_inbound_change do
          post_service_request(dual)
        end

        assert_response :conflict
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "conflict", body.dig("issue", 0, "code")
      end

      test "same identifier with a different subject identifier returns 409 and leaves stored referral unchanged" do
        post_service_request(valid_service_request(identifier_value: "REF-SUBJECT-CONFLICT"))
        assert_response :created
        first_body = JSON.parse(response.body)
        stored = Lakeraven::EHR::InboundReferral.find_by!(public_id: first_body["id"])

        altered = valid_service_request(identifier_value: "REF-SUBJECT-CONFLICT")
        altered["subject"] = {
          "identifier" => {
            "system" => PATIENT_ID_SYSTEM,
            "value" => "MRN-OTHER-PATIENT-0002"
          }
        }

        assert_no_inbound_change do
          post_service_request(altered)
        end

        assert_response :conflict
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "conflict", body.dig("issue", 0, "code")

        stored.reload
        assert_equal PATIENT_MRN, stored.patient_identifier_value
        assert_equal PATIENT_MRN, stored.resource.dig("subject", "identifier", "value")
      end

      test "identifier order does not affect idempotent replay" do
        id_a = { "system" => REFERRAL_ID_SYSTEM, "value" => "REF-ORDER-A" }
        id_b = { "system" => "#{REFERRAL_ID_SYSTEM}/secondary", "value" => "REF-ORDER-B" }

        post_service_request(valid_service_request(identifier: [ id_a, id_b ]))
        assert_response :created
        first_id = JSON.parse(response.body)["id"]

        assert_no_inbound_change do
          post_service_request(valid_service_request(identifier: [ id_b, id_a ]))
        end

        assert_response :ok
        assert_equal first_id, JSON.parse(response.body)["id"]
      end

      test "partial identifier replay does not add new identifiers" do
        id_a = { "system" => REFERRAL_ID_SYSTEM, "value" => "REF-PARTIAL-A" }
        id_c = { "system" => "#{REFERRAL_ID_SYSTEM}/extra", "value" => "REF-PARTIAL-C" }

        post_service_request(valid_service_request(identifier: [ id_a ]))
        assert_response :created
        first_id = JSON.parse(response.body)["id"]

        assert_no_inbound_change do
          assert_equal 1, inbound_identifier_count
          post_service_request(valid_service_request(identifier: [ id_a, id_c ]))
        end

        assert_response :ok
        assert_equal first_id, JSON.parse(response.body)["id"]
        assert_equal 1, inbound_identifier_count
      end

      test "RecordNotUnique on insert resolves to 200 with the existing referral" do
        id_value = "REF-RACE-0001"
        winner = seed_inbound_referral!(identifier_value: id_value)

        miss_once = true
        original_lookup = Lakeraven::EHR::InboundReferralIntake.instance_method(:matching_referral_ids)
        Lakeraven::EHR::InboundReferralIntake.define_method(:matching_referral_ids) do
          if miss_once
            miss_once = false
            []
          else
            original_lookup.bind(self).call
          end
        end

        begin
          assert_no_inbound_change do
            post_service_request(valid_service_request(identifier_value: id_value))
          end

          assert_response :ok
          assert_equal winner.public_id, JSON.parse(response.body)["id"]
          assert_equal 1, inbound_referral_count
        ensure
          Lakeraven::EHR::InboundReferralIntake.define_method(:matching_referral_ids, original_lookup)
        end
      end

      # -- Validation (422) -----------------------------------------------------

      test "resourceType other than ServiceRequest returns 422 without storing" do
        assert_rejected_validation(valid_service_request(resource_type: "Patient"))
      end

      test "Bundle body returns 422 without storing" do
        assert_rejected_validation(
          "resourceType" => "Bundle",
          "type" => "collection",
          "entry" => [ { "resource" => valid_service_request } ]
        )
      end

      test "missing status returns 422 without storing" do
        payload = valid_service_request
        payload.delete("status")
        assert_rejected_validation(payload)
      end

      test "status outside draft or active returns 422 without storing" do
        assert_rejected_validation(valid_service_request(status: "completed"))
      end

      test "missing intent returns 422 without storing" do
        payload = valid_service_request
        payload.delete("intent")
        assert_rejected_validation(payload)
      end

      test "intent outside RequestIntent returns 422 without storing" do
        assert_rejected_validation(valid_service_request(intent: "not-a-request-intent"))
      end

      test "missing identifier returns 422 without storing" do
        payload = valid_service_request
        payload.delete("identifier")
        assert_rejected_validation(payload)
      end

      test "identifier entry missing system returns 422 without storing" do
        assert_rejected_validation(
          valid_service_request(identifier: [ { "value" => REFERRAL_ID_VALUE } ])
        )
      end

      test "identifier entry missing value returns 422 without storing" do
        assert_rejected_validation(
          valid_service_request(identifier: [ { "system" => REFERRAL_ID_SYSTEM } ])
        )
      end

      test "missing subject returns 422 without storing" do
        payload = valid_service_request
        payload.delete("subject")
        assert_rejected_validation(payload)
      end

      test "subject with reference only and no identifier returns 422 without storing" do
        assert_rejected_validation(
          valid_service_request(subject: { "reference" => "Patient/123" })
        )
      end

      test "subject identifier missing system returns 422 without storing" do
        assert_rejected_validation(
          valid_service_request(subject: { "identifier" => { "value" => PATIENT_MRN } })
        )
      end

      test "subject identifier missing value returns 422 without storing" do
        assert_rejected_validation(
          valid_service_request(subject: { "identifier" => { "system" => PATIENT_ID_SYSTEM } })
        )
      end

      test "missing code returns 422 without storing" do
        payload = valid_service_request
        payload.delete("code")
        assert_rejected_validation(payload)
      end

      test "code without coding or text returns 422 without storing" do
        assert_rejected_validation(valid_service_request(code: {}))
      end

      test "code with coding entries but no non-blank code returns 422 without storing" do
        [
          [ {} ],
          [ "junk" ],
          [ { "system" => "http://snomed.info/sct", "code" => "" } ]
        ].each do |coding|
          assert_rejected_validation(
            valid_service_request(
              identifier_value: "REF-CODE-EMPTY-#{coding.hash.abs}",
              code: { "coding" => coding }
            )
          )
        end
      end

      test "code with text only and no coding returns 201" do
        assert_difference -> { inbound_referral_count }, 1 do
          post_service_request(
            valid_service_request(
              identifier_value: "REF-CODE-TEXT-ONLY",
              code: { "text" => "Referral for specialist consult" }
            )
          )
        end

        assert_response :created
      end

      test "over-long identifier and subject values return 422 OperationOutcome without storing" do
        assert_rejected_validation(
          valid_service_request(identifier: [ { "system" => REFERRAL_ID_SYSTEM, "value" => "x" * 300 } ])
        )
        assert_rejected_validation(
          valid_service_request(identifier: [ { "system" => "s" * 1100, "value" => "REF-LONG-SYSTEM" } ])
        )
        assert_rejected_validation(
          valid_service_request(
            subject: {
              "identifier" => {
                "system" => PATIENT_ID_SYSTEM,
                "value" => "m" * 300
              }
            },
            identifier_value: "REF-LONG-SUBJECT"
          )
        )
      end

      test "NUL bytes in string fields return 422 without storing" do
        assert_rejected_validation(
          valid_service_request(
            identifier: [ { "system" => REFERRAL_ID_SYSTEM, "value" => "REF-NUL-\u0000" } ]
          )
        )

        payload = valid_service_request(identifier_value: "REF-NUL-NOTE")
        payload["note"] = [ { "text" => "before\u0000after" } ]
        assert_rejected_validation(payload)
      end

      test "unparseable JSON returns 400 OperationOutcome" do
        assert_no_inbound_change do
          post CREATE_PATH,
               params: "{not json",
               headers: @headers.merge("Content-Type" => "application/fhir+json")
        end

        assert_response :bad_request
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "Content-Type application/json accepts a valid body" do
        assert_difference -> { inbound_referral_count }, 1 do
          post CREATE_PATH,
               params: valid_service_request_json(identifier_value: "REF-JSON-CT-VALID"),
               headers: @headers.merge("Content-Type" => "application/json")
        end

        assert_response :created
      end

      test "Content-Type application/json with invalid JSON returns 400 and writes exactly one AuditEvent" do
        assert_difference -> { AuditEvent.count }, 1 do
          assert_no_inbound_change do
            post CREATE_PATH,
                 params: "{not json",
                 headers: @headers.merge("Content-Type" => "application/json")
          end
        end

        assert_response :bad_request
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "Content-Type text/plain returns 415 OperationOutcome without storing" do
        assert_no_inbound_change do
          post CREATE_PATH,
               params: valid_service_request_json(identifier_value: "REF-TEXT-PLAIN"),
               headers: @headers.merge("Content-Type" => "text/plain")
        end

        assert_response :unsupported_media_type
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "JSON array body returns 400 OperationOutcome" do
        assert_no_inbound_change do
          post CREATE_PATH,
               params: [ valid_service_request ].to_json,
               headers: @headers.merge("Content-Type" => "application/fhir+json")
        end

        assert_response :bad_request
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "Content-Length over one megabyte returns 413 without reading the request body" do
        original_intake = Lakeraven::EHR::ServiceRequestsController.instance_method(:intake_resource)
        body_read = false
        Lakeraven::EHR::ServiceRequestsController.define_method(:intake_resource) do
          body_read = true
          original_intake.bind(self).call
        end

        begin
          assert_no_inbound_change do
            post CREATE_PATH,
                 params: valid_service_request_json(identifier_value: "REF-CONTENT-LENGTH"),
                 headers: @headers.merge(
                   "Content-Type" => "application/fhir+json",
                   "CONTENT_LENGTH" => "2000000"
                 )
          end

          assert_response :content_too_large
          refute body_read, "expected 413 before the controller reads the body"
          assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
        ensure
          Lakeraven::EHR::ServiceRequestsController.define_method(:intake_resource, original_intake)
        end
      end

      test "body larger than one megabyte returns 413 and stores nothing" do
        oversized = " " * (1_048_576 + 1)

        assert_no_inbound_change do
          post CREATE_PATH,
               params: oversized,
               headers: @headers.merge("Content-Type" => "application/fhir+json")
        end

        assert_response :content_too_large
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "POST on backend without prc_referrals returns not-supported for system token and stores nothing" do
        with_restricted_backend(capabilities: []) do
          assert_no_inbound_change do
            post_service_request(valid_service_request(identifier_value: "REF-NO-PRC-SYSTEM"))
          end

          assert_response :not_found
          body = JSON.parse(response.body)
          assert_equal "OperationOutcome", body["resourceType"]
          assert_equal "not-supported", body.dig("issue", 0, "code")
        end
      end

      test "POST on backend without prc_referrals returns forbidden for patient-scoped token before unavailability" do
        with_restricted_backend(capabilities: []) do
          install_oauth_client!(scopes: "patient/ServiceRequest.write", organization_id: ORGANIZATION_ID)

          assert_no_inbound_change do
            post_service_request(valid_service_request(identifier_value: "REF-NO-PRC-PATIENT"))
          end

          assert_response :forbidden
          refute_match(/not-supported/i, response.body)
        end
      end

      # -- Capability statement -------------------------------------------------

      test "metadata lists create among ServiceRequest interactions" do
        install_oauth_client!(scopes: "system/*.read", organization_id: ORGANIZATION_ID)
        get METADATA_PATH, headers: @headers

        assert_response :ok
        resources = JSON.parse(response.body).dig("rest", 0, "resource")
        service_request = resources.find { |r| r["type"] == "ServiceRequest" }
        assert service_request, "CapabilityStatement should declare ServiceRequest"
        codes = service_request.fetch("interaction").map { |i| i["code"] }
        assert_includes codes, "create"
      end

      # -- Audit ----------------------------------------------------------------

      test "successful intake writes an AuditEvent without patient MRN or referral identifier in text columns" do
        assert_difference -> { AuditEvent.count }, 1 do
          post_service_request(valid_service_request(identifier_value: "REF-AUDIT-0001"))
        end
        assert_response :created

        event = AuditEvent.recent.first
        assert_equal "C", event.action
        assert_equal "0", event.outcome
        assert_equal "ServiceRequest", event.entity_type

        text_columns = [
          event.agent_name,
          event.agent_network_address,
          event.agent_who_identifier,
          event.agent_who_type,
          event.entity_id,
          event.entity_identifier,
          event.entity_type,
          event.facility_identifier,
          event.outcome_desc,
          event.rpms_session_id,
          event.tenant_identifier
        ].compact.join(" ")

        refute_includes text_columns, PATIENT_MRN
        refute_includes text_columns, "REF-AUDIT-0001"
      end

      private

      def install_oauth_client!(scopes:, organization_id:)
        teardown_smart_auth if @oauth_app
        @oauth_app = Doorkeeper::Application.create!(
          name: "inbound referral test client",
          redirect_uri: "https://example.test/callback",
          scopes: scopes,
          confidential: true,
          organization_id: organization_id
        )
        token = Doorkeeper::AccessToken.create!(
          application: @oauth_app,
          scopes: scopes,
          expires_in: 3600
        )
        @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      def valid_service_request(**overrides)
        payload = {
          "resourceType" => "ServiceRequest",
          "status" => "active",
          "intent" => "order",
          "identifier" => [
            { "system" => REFERRAL_ID_SYSTEM, "value" => REFERRAL_ID_VALUE }
          ],
          "code" => {
            "coding" => [
              { "system" => "http://snomed.info/sct", "code" => "3457005", "display" => "Patient referral" }
            ]
          },
          "subject" => {
            "identifier" => {
              "system" => PATIENT_ID_SYSTEM,
              "value" => PATIENT_MRN
            }
          }
        }

        if overrides.key?(:resource_type)
          payload["resourceType"] = overrides.delete(:resource_type)
        end
        if overrides.key?(:client_submitted_id)
          payload["id"] = overrides.delete(:client_submitted_id)
        end
        if overrides.key?(:identifier_value)
          payload["identifier"] = [
            { "system" => REFERRAL_ID_SYSTEM, "value" => overrides.delete(:identifier_value) }
          ]
        end

        payload.merge!(overrides.stringify_keys)
        payload
      end

      def valid_service_request_json(**overrides)
        valid_service_request(**overrides).to_json
      end

      def post_service_request(payload)
        json = payload.is_a?(String) ? payload : payload.to_json
        post CREATE_PATH, params: json, headers: @headers.merge("Content-Type" => "application/fhir+json")
      end

      def inbound_referral_count
        Lakeraven::EHR::InboundReferral.count
      end

      def assert_no_inbound_change
        before = inbound_referral_count
        yield
        assert_equal before, inbound_referral_count
      end

      def assert_rejected_validation(payload)
        assert_no_inbound_change do
          post_service_request(payload)
        end

        assert_response :unprocessable_content
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "error", body.dig("issue", 0, "severity")
        refute_includes response.body, PATIENT_MRN, "diagnostics must not echo patient MRN"
        refute_includes response.body, REFERRAL_ID_VALUE, "diagnostics must not echo referral identifier value"
      end

      def inbound_identifier_count
        Lakeraven::EHR::InboundReferralIdentifier.count
      end

      def seed_inbound_referral!(identifier_value:)
        resource = valid_service_request(identifier_value: identifier_value)
        referral = Lakeraven::EHR::InboundReferral.create!(
          oauth_application_id: @oauth_app.id,
          organization_id: @oauth_app.organization_id,
          status: "received",
          patient_identifier_system: PATIENT_ID_SYSTEM,
          patient_identifier_value: PATIENT_MRN,
          resource: resource
        )
        Lakeraven::EHR::InboundReferralIdentifier.create!(
          inbound_referral: referral,
          oauth_application_id: @oauth_app.id,
          system: REFERRAL_ID_SYSTEM,
          value: identifier_value
        )
        referral
      end

      def delete_inbound_records_if_defined
        return unless Lakeraven::EHR.const_defined?(:InboundReferral, false)

        if Lakeraven::EHR.const_defined?(:InboundReferralIdentifier, false)
          Lakeraven::EHR::InboundReferralIdentifier.delete_all
        end
        Lakeraven::EHR::InboundReferral.delete_all
      end
    end
  end
end
