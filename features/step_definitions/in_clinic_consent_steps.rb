# frozen_string_literal: true

require_relative "../../test/support/consent_write_test_helper"

module InClinicConsentStepHelpers
  include ConsentWriteTestHelper

  def parse_last_response!
    @last_response = last_response
  end

  def last_body
    @last_response.body
  end

  def authentication_success_service
    result = auth_success_result(duz: PatientBannerTestHelper::DUZ)
    service = Object.new
    service.define_singleton_method(:authenticate) { |**_kwargs| result }
    service
  end
end

World(InClinicConsentStepHelpers)

Before("@in_clinic_consent") do
  enable_forgery_protection!
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
  @authentication_stub_restore = StubHelpers.install_singleton_stub(
    Lakeraven::EHR::AuthenticationService,
    :new,
    authentication_success_service
  )
end

After("@in_clinic_consent") do
  restore_forgery_protection!
  @authentication_stub_restore&.call
  @authentication_stub_restore = nil
  Doorkeeper::AccessToken.delete_all
  Doorkeeper::Application.delete_all
  Lakeraven::EHR::AuditEvent.delete_all
  Lakeraven::EHR::SignedConsent.delete_all if defined?(Lakeraven::EHR::SignedConsent) && Lakeraven::EHR::SignedConsent.table_exists?
  Lakeraven::EHR::ConsentTemplate.delete_all if defined?(Lakeraven::EHR::ConsentTemplate) && Lakeraven::EHR::ConsentTemplate.table_exists?
  if @demo_original_client
    RpmsRpc.configure { |c| c.client = @demo_original_client }
    @demo_original_client = nil
  end
end

Given("default consent templates are installed") do
  install_consent_templates!
end

Given("the clinician is signed in with consent write scopes for in-clinic signing") do
  sign_in_clinician_for_consent!(scopes: ConsentWriteTestHelper::WRITE_SCOPES, security_keys: %w[orders_sign])
  open_patient_context!(@dfn) if @dfn
  install_consent_templates!
  parse_last_response!
end

Given("the clinician starts the {string} consent handover") do |template_key|
  sign_in_clinician_for_consent!(scopes: ConsentWriteTestHelper::WRITE_SCOPES, security_keys: %w[orders_sign]) unless @clinician_token
  open_patient_context!(@dfn) if @dfn
  post_handover(template_key: template_key)
  follow_redirect! if last_response.redirect?
  parse_last_response!
end

Given("the clinician opens the patient consent list") do
  sign_in_clinician_for_consent!(scopes: ConsentWriteTestHelper::WRITE_SCOPES, security_keys: %w[orders_sign]) unless @clinician_token
  open_patient_context!(@dfn) if @dfn
  get ConsentWriteTestHelper::BASE
  parse_last_response!
  @consents_list_audit_before = Lakeraven::EHR::AuditEvent.count
end

When("the patient signs the kiosk consent form") do
  post_kiosk_signature
  parse_last_response!
  @last_signature_bytes = ConsentWriteTestHelper::TINY_PNG
  @last_signer_name = ConsentWriteTestHelper::SYNTHETIC_SIGNER_NAME
end

When("the patient signs the kiosk consent form with typed name {string}") do |name|
  post_kiosk_signature(signer_name: name)
  parse_last_response!
  @last_signature_bytes = ConsentWriteTestHelper::TINY_PNG
  @last_signer_name = name
end

When("the clinician unlocks the kiosk with their access and verify codes") do
  post_kiosk_unlock(access_code: "SYNTHETIC.ACCESS", verify_code: "SYNTHETIC.VERIFY")
  follow_redirect! if last_response.redirect?
  parse_last_response!
end

Then("a signed consent exists for the patient with template version witness and signature") do
  rows = Lakeraven::EHR::SignedConsent.signatures_for_patient(@dfn)
  assert_equal 1, rows.size, "expected one signature row"
  row = rows.first
  template = Lakeraven::EHR::ConsentTemplate.current(ConsentWriteTestHelper::TEMPLATE_BH)
  assert_equal template.version, row.template_version
  assert_equal template.key, row.template_key
  assert_equal PatientBannerTestHelper::DUZ, row.witness_duz
  assert row.signature_png.start_with?(ConsentWriteTestHelper::PNG_MAGIC)
end

Then("the chart consent list shows the consent as Active") do
  get ConsentWriteTestHelper::BASE
  parse_last_response!
  assert_match(/Active/i, last_body)
end

Then("the chart consent list shows the consent as Revoked") do
  get ConsentWriteTestHelper::BASE
  parse_last_response!
  assert_match(/Revoked/i, last_body)
end

Then("the kiosk shows only the consent template and patient name and date of birth") do
  template = Lakeraven::EHR::ConsentTemplate.current(ConsentWriteTestHelper::TEMPLATE_BH)
  assert_includes last_body, template.title
  assert_includes last_body, template.body
  assert_includes last_body, @patient_display_name
  assert_includes last_body, demo_patient_dob_fragment
  refute_includes last_body, "900-00-0103"
  refute_includes last_body, "Prenatal Vitamin"
end

Then("the kiosk has no navigation search or chart links") do
  doc = Nokogiri::HTML(last_body)
  assert_empty doc.css("a[href]")
  assert_nil doc.at_css("form#patient-search")
  assert_nil doc.at_css("form[action*='chart_search']")
end

When("the clinician attempts to edit the signed consent") do
  row = Lakeraven::EHR::SignedConsent.signatures_for_patient(@dfn).first
  @signed_consent_id = row.id
  @digest_before_edit = row.template_body_digest
  @edit_attempt_failed = false
  begin
    banner_request(:patch, "#{ConsentWriteTestHelper::BASE}/#{row.id}", { authenticity_token: csrf_token })
    parse_last_response!
  rescue ActionController::RoutingError
    @edit_attempt_failed = true
  end
end

Then("the edit is refused and the stored consent is unchanged") do
  assert @edit_attempt_failed || last_response.status.in?([ 404, 405 ]),
         "expected routing failure or 404/405, got #{last_response.status}"
  row = Lakeraven::EHR::SignedConsent.find(@signed_consent_id)
  assert_equal @digest_before_edit, row.template_body_digest
end

When("the clinician records a revocation with a synthetic reason") do
  row = Lakeraven::EHR::SignedConsent.signatures_for_patient(@dfn).first
  banner_request(:post, "#{ConsentWriteTestHelper::BASE}/#{row.id}/revocation",
                 {
                   reason: ConsentWriteTestHelper::SYNTHETIC_REVOCATION_REASON,
                   authenticity_token: csrf_token
                 })
  parse_last_response!
end

Then("audit events exist for consent list view kiosk view sign and revoke") do
  actions = Lakeraven::EHR::AuditEvent.order(:created_at).pluck(:action)
  assert_includes actions, "R"
  assert_includes actions, "C"
  assert actions.count("R") >= 2, "expected list and kiosk reads, got #{actions.inspect}"
  assert actions.count("C") >= 2, "expected sign and revoke creates, got #{actions.inspect}"
end

Then("no audit event contains the signature image or typed signer name") do
  encoded = Base64.strict_encode64(@last_signature_bytes || ConsentWriteTestHelper::TINY_PNG)[0, 32]
  Lakeraven::EHR::AuditEvent.find_each do |event|
    blob = [ event.entity_identifier, event.outcome_desc, event.agent_who_identifier ].compact.join(" ")
    refute_includes blob, encoded
    refute_includes blob, @last_signer_name if @last_signer_name
  end
end

Then("the clinician returns to the patient consent list") do
  assert_match(/consent/i, last_body)
  assert_equal ConsentWriteTestHelper::BASE, URI.parse(last_request.url).path
end
