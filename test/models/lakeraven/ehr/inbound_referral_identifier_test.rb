# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class InboundReferralIdentifierTest < ActiveSupport::TestCase
      REFERRAL_ID_SYSTEM = "https://snf.example.test/referrals"
      REFERRAL_ID_VALUE = "REF-UNIQUE-0001"

      teardown do
        next unless Lakeraven::EHR.const_defined?(:InboundReferralIdentifier, false)

        Lakeraven::EHR::InboundReferralIdentifier.delete_all
        Lakeraven::EHR::InboundReferral.delete_all if Lakeraven::EHR.const_defined?(:InboundReferral, false)
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      test "duplicate oauth_application_id system value raises RecordNotUnique bypassing validations" do
        app = Doorkeeper::Application.create!(
          name: "identifier uniqueness test",
          redirect_uri: "https://example.test/callback",
          scopes: "system/ServiceRequest.write",
          confidential: true,
          organization_id: "example-organization-identifier-test"
        )

        referral_model = Lakeraven::EHR::InboundReferral
        identifier_model = Lakeraven::EHR::InboundReferralIdentifier

        first_referral = referral_model.create!(
          public_id: SecureRandom.uuid,
          oauth_application_id: app.id,
          organization_id: app.organization_id,
          status: "received",
          patient_identifier_system: "https://example.test/mrn",
          patient_identifier_value: "MRN-TEST-0001",
          resource: { "resourceType" => "ServiceRequest", "status" => "active" }
        )
        second_referral = referral_model.create!(
          public_id: SecureRandom.uuid,
          oauth_application_id: app.id,
          organization_id: app.organization_id,
          status: "received",
          patient_identifier_system: "https://example.test/mrn",
          patient_identifier_value: "MRN-TEST-0002",
          resource: { "resourceType" => "ServiceRequest", "status" => "active" }
        )

        identifier_model.create!(
          inbound_referral: first_referral,
          oauth_application_id: app.id,
          system: REFERRAL_ID_SYSTEM,
          value: REFERRAL_ID_VALUE
        )

        duplicate = identifier_model.new(
          inbound_referral: second_referral,
          oauth_application_id: app.id,
          system: REFERRAL_ID_SYSTEM,
          value: REFERRAL_ID_VALUE
        )

        assert_raises(ActiveRecord::RecordNotUnique) do
          duplicate.save(validate: false)
        end
      end
    end
  end
end
