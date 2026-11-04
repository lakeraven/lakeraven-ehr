# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/consent_write_test_helper"

module Lakeraven
  module EHR
    class SignedConsentRound4Test < ActiveSupport::TestCase
      include ConsentWriteTestHelper

      setup do
        install_consent_templates!
      end

      teardown do
        SignedConsent.delete_all if SignedConsent.table_exists?
        ConsentTemplate.delete_all if ConsentTemplate.table_exists?
      end

      def signature_attrs(signer_name: SYNTHETIC_SIGNER_NAME)
        template = ConsentTemplate.current(TEMPLATE_BH)
        {
          patient_dfn: DFN,
          consent_template: template,
          template_key: TEMPLATE_BH,
          template_version: template.version,
          template_body_digest: body_digest(template.body),
          signature_png: TINY_PNG,
          signer_name: signer_name,
          signed_at: Time.zone.now,
          witness_duz: DUZ,
          kind: SignedConsent::KIND_SIGNATURE,
          recorded_by_duz: DUZ
        }
      end

      test "signer_name containing a NUL byte is invalid without raising on valid?" do
        row = SignedConsent.new(signature_attrs(signer_name: "SYNTHETIC\u0000SIGNER"))
        assert_nothing_raised { refute row.valid? }
      end

      test "revocation row with NUL in revocation_reason is invalid without raising on valid?" do
        signature = SignedConsent.create!(signature_attrs)
        row = SignedConsent.new(
          patient_dfn: DFN,
          consent_template: signature.consent_template,
          template_key: TEMPLATE_BH,
          template_version: signature.template_version,
          template_body_digest: signature.template_body_digest,
          signed_at: Time.zone.now,
          witness_duz: DUZ,
          kind: SignedConsent::KIND_REVOCATION,
          recorded_by_duz: DUZ,
          revokes_id: signature.id,
          revocation_reason: "SYNTHETIC\u0000REVOCATION"
        )
        assert_nothing_raised { refute row.valid? }
      end
    end
  end
end
