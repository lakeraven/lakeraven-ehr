# frozen_string_literal: true

require "test_helper"
require_relative "../../../dummy/lib/lakeraven_demo_seeds"
require_relative "../../../support/consent_write_test_helper"

module Lakeraven
  module EHR
    class ConsentsControllerTest < ActionDispatch::IntegrationTest
      include ConsentWriteTestHelper

      setup do
        @forgery_was = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        Lakeraven::EHR::AuditEvent.delete_all
        @demo_original_client = RpmsRpc.configuration.client
        RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
        sign_in_clinician!(scopes: WRITE_SCOPES)
        open_patient_context!(DFN)
        install_consent_templates!
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @forgery_was
        teardown_oauth!
        Lakeraven::EHR::AuditEvent.delete_all
        SignedConsent.delete_all if defined?(SignedConsent) && SignedConsent.table_exists?
        ConsentTemplate.delete_all if defined?(ConsentTemplate) && ConsentTemplate.table_exists?
        if @demo_original_client
          RpmsRpc.configure { |c| c.client = @demo_original_client }
          @demo_original_client = nil
        end
      end

      test "GET index lists each consent with template title version and status" do
        signature = SignedConsent.create!(
          patient_dfn: DFN,
          consent_template: ConsentTemplate.current(TEMPLATE_BH),
          template_key: TEMPLATE_BH,
          template_version: 1,
          template_body_digest: body_digest(ConsentTemplate.current(TEMPLATE_BH).body),
          signature_png: TINY_PNG,
          signed_at: Time.zone.now,
          witness_duz: DUZ,
          kind: "signature",
          recorded_by_duz: DUZ
        )

        get BASE

        assert_response :ok
        template = ConsentTemplate.current(TEMPLATE_BH)
        assert_select "td", text: template.title
        assert_select "td", text: /#{template.version}/
        assert_select "td", text: /Active/i
        assert_select "td", text: /Revoked/i, count: 0

        signature.revoke!(by_duz: DUZ, reason: SYNTHETIC_REVOCATION_REASON)
        get BASE
        assert_select "td", text: /Revoked/i
      end

      test "GET new offers the three template choices" do
        get "#{BASE}/new"

        assert_response :ok
        assert_select "form[action=?][method=post]", HANDOVER do
          assert_select "button[type=submit], input[type=submit]", minimum: 3
        end
        assert_match(/bh treatment|telehealth|release of information/i, response.body)
      end

      test "POST handover locks session and redirects to kiosk for a known template" do
        assert_difference -> { AuditEvent.count }, +1 do
          post_handover
        end

        assert_redirected_to KIOSK
        event = AuditEvent.recent.first
        assert_equal "E", event.action
        assert_equal "Patient", event.entity_type
        assert_equal DFN, event.entity_identifier
        assert_equal DUZ, event.agent_who_identifier
      end

      test "POST handover with unknown template key is 404 and does not lock" do
        post_handover(template_key: "not-a-real-template")
        assert_response :not_found

        get CHART
        assert_response :ok
      end

      test "POST revocation marks consent revoked on the list without changing the signature row" do
        signature = SignedConsent.create!(
          patient_dfn: DFN,
          consent_template: ConsentTemplate.current(TEMPLATE_BH),
          template_key: TEMPLATE_BH,
          template_version: 1,
          template_body_digest: body_digest(ConsentTemplate.current(TEMPLATE_BH).body),
          signature_png: TINY_PNG,
          signed_at: Time.zone.now,
          witness_duz: DUZ,
          kind: "signature",
          recorded_by_duz: DUZ
        )
        digest_before = signature.template_body_digest

        assert_difference -> { AuditEvent.count }, +1 do
          post "#{BASE}/#{signature.id}/revocation",
               params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: csrf_token }
        end

        assert_response :redirect
        signature.reload
        assert_equal digest_before, signature.template_body_digest
        get BASE
        assert_select "td", text: /Revoked/i
      end

      test "no PATCH PUT or DELETE route edits a signed consent" do
        signature = SignedConsent.create!(
          patient_dfn: DFN,
          consent_template: ConsentTemplate.current(TEMPLATE_BH),
          template_key: TEMPLATE_BH,
          template_version: 1,
          template_body_digest: body_digest(ConsentTemplate.current(TEMPLATE_BH).body),
          signature_png: TINY_PNG,
          signed_at: Time.zone.now,
          witness_duz: DUZ,
          kind: "signature",
          recorded_by_duz: DUZ
        )
        digest_before = signature.template_body_digest

        %i[patch put delete].each do |verb|
          send(verb, "#{BASE}/#{signature.id}", params: { authenticity_token: csrf_token })
          assert_response :not_found, "expected #{verb.upcase} #{BASE}/#{signature.id} to be unrouted"
        end

        signature.reload
        assert_equal digest_before, signature.template_body_digest
      end

      test "token without consent write scope refuses revocation and stores nothing" do
        signature = SignedConsent.create!(
          patient_dfn: DFN,
          consent_template: ConsentTemplate.current(TEMPLATE_BH),
          template_key: TEMPLATE_BH,
          template_version: 1,
          template_body_digest: body_digest(ConsentTemplate.current(TEMPLATE_BH).body),
          signature_png: TINY_PNG,
          signed_at: Time.zone.now,
          witness_duz: DUZ,
          kind: "signature",
          recorded_by_duz: DUZ
        )

        reset!
        sign_in_clinician!(scopes: READ_SCOPES)
        open_patient_context!(DFN)

        assert_no_difference -> { SignedConsent.where(kind: "revocation").count } do
          post "#{BASE}/#{signature.id}/revocation",
               params: { reason: SYNTHETIC_REVOCATION_REASON, authenticity_token: csrf_token }
        end

        assert_response :forbidden
      end

      test "patient context must be open for consent writes" do
        reset!
        sign_in_clinician!(scopes: WRITE_SCOPES)

        post_handover
        assert_response :forbidden
      end

      test "GET index is audited as a read of the patient chart consents" do
        AuditEvent.delete_all

        assert_difference -> { AuditEvent.count }, +1 do
          get BASE
        end

        event = AuditEvent.recent.first
        assert_equal "R", event.action
        assert_equal "Patient", event.entity_type
        assert_equal DFN, event.entity_identifier
      end

      test "kiosk sign is not stored when audit insert fails" do
        open_kiosk_via_handover!

        with_broken_audit do
          post_kiosk_signature
        end

        assert_response :service_unavailable
        assert_equal 0, SignedConsent.count
      end
    end
  end
end
