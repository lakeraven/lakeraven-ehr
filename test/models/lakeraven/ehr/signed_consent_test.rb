# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/consent_write_test_helper"

module Lakeraven
  module EHR
    class SignedConsentTest < ActiveSupport::TestCase
      include ConsentWriteTestHelper

      setup do
        SignedConsent.delete_all if defined?(SignedConsent) && SignedConsent.table_exists?
        ConsentTemplate.delete_all if defined?(ConsentTemplate) && ConsentTemplate.table_exists?
        install_consent_templates!
        @template = ConsentTemplate.current(TEMPLATE_BH)
        @signed_at = Time.zone.parse("2026-11-03 10:15:00")
      end

      def valid_attrs
        {
          patient_dfn: DFN,
          consent_template: @template,
          template_key: @template.key,
          template_version: @template.version,
          template_body_digest: body_digest(@template.body),
          signer_name: SYNTHETIC_SIGNER_NAME,
          signature_png: TINY_PNG,
          signed_at: @signed_at,
          witness_duz: DUZ,
          kind: "signature",
          recorded_by_duz: DUZ
        }
      end

      test "a signature row is valid with required attributes" do
        row = SignedConsent.new(valid_attrs)
        assert row.valid?, row.errors.full_messages.to_sentence
      end

      test "signature requires PNG magic bytes and rejects blank or non-PNG data" do
        refute SignedConsent.new(valid_attrs.merge(signature_png: nil)).valid?
        refute SignedConsent.new(valid_attrs.merge(signature_png: "")).valid?
        refute SignedConsent.new(valid_attrs.merge(signature_png: "not-a-png")).valid?
      end

      test "signature rejects payloads over 500 KB" do
        huge = TINY_PNG + ("x" * (500.kilobytes + 1))
        refute SignedConsent.new(valid_attrs.merge(signature_png: huge)).valid?
      end

      test "invalid signature is not persisted" do
        assert_no_difference -> { SignedConsent.count } do
          SignedConsent.create(valid_attrs.merge(signature_png: "bad"))
        end
      end

      test "a persisted signature is immutable" do
        row = SignedConsent.create!(valid_attrs)
        original_digest = row.template_body_digest

        assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(signer_name: "changed") }
        assert_raises(ActiveRecord::ReadOnlyRecord) { row.update_column(:signer_name, "changed") }
        assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }

        row.reload
        assert_equal original_digest, row.template_body_digest
      end

      test "revoke! creates a new revocation row and leaves the signature unchanged" do
        signature = SignedConsent.create!(valid_attrs)
        before = signature.attributes.slice("signer_name", "template_body_digest", "witness_duz")

        revocation = signature.revoke!(by_duz: DUZ, reason: SYNTHETIC_REVOCATION_REASON)

        assert_equal "revocation", revocation.kind
        assert_equal signature.id, revocation.revokes_id
        assert_equal SYNTHETIC_REVOCATION_REASON, revocation.revocation_reason

        signature.reload
        assert_equal before, signature.attributes.slice("signer_name", "template_body_digest", "witness_duz")
      end

      test "revoking twice is refused" do
        signature = SignedConsent.create!(valid_attrs)
        signature.revoke!(by_duz: DUZ, reason: SYNTHETIC_REVOCATION_REASON)

        assert_raises(StandardError) do
          signature.revoke!(by_duz: DUZ, reason: "second attempt")
        end
        assert_equal 1, SignedConsent.where(kind: "revocation", revokes_id: signature.id).count
      end

      test "a revocation row cannot itself be revoked" do
        signature = SignedConsent.create!(valid_attrs)
        revocation = signature.revoke!(by_duz: DUZ, reason: SYNTHETIC_REVOCATION_REASON)

        assert_raises(StandardError) { revocation.revoke!(by_duz: DUZ, reason: "nope") }
      end

      test "signatures_for_patient returns only that patient's signature rows" do
        mine = SignedConsent.create!(valid_attrs)
        SignedConsent.create!(valid_attrs.merge(patient_dfn: OTHER_DFN))

        listed = SignedConsent.signatures_for_patient(DFN)
        assert_equal [ mine.id ], listed.map(&:id)
      end

      test "to_consent maps an active signature to an enforceable Consent" do
        signature = SignedConsent.create!(valid_attrs)
        consent = signature.to_consent

        assert_instance_of Consent, consent
        assert_equal DFN, consent.patient_dfn
        assert_equal @template.consent_scope, consent.scope
        assert_equal "active", consent.status
        assert_equal "permit", consent.provision_type
        assert_equal DUZ, consent.performer_ien
        assert_equal @signed_at.to_date, consent.date_time
      end

      test "to_consent reports revoked when a revocation exists" do
        signature = SignedConsent.create!(valid_attrs)
        signature.revoke!(by_duz: DUZ, reason: SYNTHETIC_REVOCATION_REASON)

        assert_equal "revoked", signature.to_consent.status
      end
    end
  end
end
