# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/consent_write_test_helper"

# PR #805 threads 3–4: consent list start link and revocation query batching.
class ConsentPr805IndexTest < ActionDispatch::IntegrationTest
  include ConsentWriteTestHelper

  NEW_CONSENT_PATH = "#{MOUNT}/patients/#{DFN}/consents/new"

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all
    @demo_original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    sign_in_clinician_for_consent!(scopes: WRITE_SCOPES)
    open_patient_context!(DFN)
    install_consent_templates!
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    Lakeraven::EHR::LoginThrottle.reset!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::SignedConsent.delete_all if Lakeraven::EHR::SignedConsent.table_exists?
    Lakeraven::EHR::KioskLock.delete_all if Lakeraven::EHR::KioskLock.table_exists?
    Lakeraven::EHR::ConsentTemplate.delete_all if Lakeraven::EHR::ConsentTemplate.table_exists?
    Lakeraven::EHR.reset_configuration!
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  test "consent index offers Start a consent when patient has no consents yet" do
    assert_equal 0, Lakeraven::EHR::SignedConsent.count

    get BASE
    assert_response :ok
    assert_select "a[href=?]", NEW_CONSENT_PATH, text: "Start a consent"

    get NEW_CONSENT_PATH
    assert_response :ok
    assert_includes response.body, Lakeraven::EHR::ConsentTemplate.current(TEMPLATE_BH).title
  end

  test "consent index offers Start a consent when patient already has signed consents" do
    create_signature_row!(template_key: TEMPLATE_BH)

    get BASE
    assert_response :ok
    assert_select "a[href=?]", NEW_CONSENT_PATH, text: "Start a consent"
  end

  test "user without Consent read scope cannot open the consent list or see Start a consent" do
    reset!
    sign_in_clinician_for_consent!(scopes: PatientBannerTestHelper::BANNER_SCOPES)
    open_patient_context!(DFN)

    get BASE
    assert_response :forbidden
    refute_includes response.body, "Start a consent"
  end

  test "consent index does not run per-row revocation EXISTS queries" do
    one_row_queries = revocation_table_queries_during { create_and_list!(count: 1) }
    four_row_queries = revocation_table_queries_during { create_and_list!(count: 4) }

    assert_operator one_row_queries, :<=, 1,
                    "expected at most one revocation-table query for one consent, got #{one_row_queries}"
    assert_equal one_row_queries, four_row_queries,
                 "revocation-table query count must not grow with list rows (1 => #{one_row_queries}, 4 => #{four_row_queries})"
  end

  private

  def create_and_list!(count:)
    Lakeraven::EHR::SignedConsent.delete_all
    count.times { |i| create_signature_row!(template_key: i.even? ? TEMPLATE_BH : TEMPLATE_ROI) }
    get BASE
    assert_response :ok
  end

  def create_signature_row!(template_key:)
    template = Lakeraven::EHR::ConsentTemplate.current(template_key)
    Lakeraven::EHR::SignedConsent.create!(
      patient_dfn: DFN,
      consent_template: template,
      template_key: template.key,
      template_version: template.version,
      template_body_digest: body_digest(template.body),
      signature_png: TINY_PNG,
      signed_at: Time.zone.now,
      witness_duz: DUZ,
      kind: "signature",
      recorded_by_duz: DUZ
    )
  end

  def revocation_table_queries_during
    table = Lakeraven::EHR::SignedConsent.table_name
    count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next unless sql.include?(table)
      next unless sql.match?(/revocation|revokes_id|EXISTS/i)

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end
    count
  end
end
