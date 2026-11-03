# frozen_string_literal: true

require "zlib"
require_relative "patient_banner_test_helper"

# Shared helpers for in-clinic consent specification (#793).
module ConsentWriteTestHelper
  include PatientBannerTestHelper

  DFN = "3"
  OTHER_DFN = "2"
  MOUNT = PatientBannerTestHelper::MOUNT
  BASE = "#{MOUNT}/patients/#{DFN}/consents"
  KIOSK = "#{MOUNT}/consent_kiosk"
  KIOSK_UNLOCK = "#{KIOSK}/unlock"
  CHART = "#{MOUNT}/patients/#{DFN}"
  HANDOVER = "#{BASE}/handover"
  DASHBOARD = "#{MOUNT}/dashboard"
  CHART_SEARCH = "#{MOUNT}/chart_search"
  PATIENT_SEARCH = "#{MOUNT}/patients/search"

  TEMPLATE_BH = "bh-treatment"
  TEMPLATE_TELEHEALTH = "telehealth"
  TEMPLATE_ROI = "release-of-information"

  SYNTHETIC_SIGNER_NAME = "Testpatient, Alpha"
  SYNTHETIC_REVOCATION_REASON = "SYNTHETIC-REVOCATION-REASON-793"

  PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze

  def self.png_chunk(type, data)
    [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
  end

  def self.inked_png_bytes(width:, height:, &block)
    block ||= proc { |_x, _y| [ 0, 0, 0, 255 ] }
    raw = (+"").tap do |rows|
      height.times do |y|
        rows << "\x00"
        width.times do |x|
          rows << block.call(x, y).pack("C*")
        end
      end
    end
    header = [ width, height, 8, 6, 0, 0, 0 ].pack("NNCCCCC")
    PNG_MAGIC + png_chunk("IHDR", header) +
      png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
      png_chunk("IEND", "")
  end

  def self.fully_transparent_png(width: 60, height: 20)
    inked_png_bytes(width: width, height: height) { |_x, _y| [ 0, 0, 0, 0 ] }
  end

  # Valid 1×1 PNG with one opaque pixel (not a blank canvas).
  TINY_PNG = inked_png_bytes(width: 1, height: 1).freeze

  def magic_bytes_only_png
    PNG_MAGIC
  end

  def corrupt_truncated_png
    TINY_PNG.byteslice(0, 20)
  end

  def fully_transparent_signature_png
    ConsentWriteTestHelper.fully_transparent_png
  end

  WRITE_SCOPES = [
    "user/Patient.read",
    "user/Consent.read",
    "user/Consent.write",
    "user/AllergyIntolerance.read",
    "user/Condition.read",
    "user/MedicationRequest.read",
    "user/Observation.read",
    "user/QuestionnaireResponse.read",
    "user/QuestionnaireResponse.write"
  ].join(" ")

  READ_SCOPES = WRITE_SCOPES.gsub("user/Consent.write", "").squeeze(" ")

  def signature_data_url(bytes = TINY_PNG)
    "data:image/png;base64,#{Base64.strict_encode64(bytes)}"
  end

  def body_digest(body)
    Digest::SHA256.hexdigest(body.to_s)
  end

  def with_failing(klass, method, replacement)
    singleton = klass.singleton_class
    original = singleton.instance_method(method) if singleton.method_defined?(method)
    original = nil unless original&.owner == singleton

    klass.define_singleton_method(method, &replacement)
    yield
  ensure
    singleton.send(:remove_method, method)
    singleton.send(:define_method, method, original) if original
  end

  def with_broken_audit(&block)
    with_failing(Lakeraven::EHR::AuditEvent, :create!, ->(*) { raise ActiveRecord::StatementInvalid, "audit down" }, &block)
  end

  def refute_signature_phi_in_audit_rows!
    Lakeraven::EHR::AuditEvent.find_each do |event|
      blob = [ event.entity_identifier, event.outcome_desc, event.agent_who_identifier ].compact.join(" ")
      refute_includes blob, Base64.strict_encode64(TINY_PNG)[0, 32]
      refute_includes blob, SYNTHETIC_SIGNER_NAME
    end
  end

  def refute_signature_phi_in_logs!(logs)
    refute_includes logs, Base64.strict_encode64(TINY_PNG)[0, 32]
    refute_includes logs, SYNTHETIC_SIGNER_NAME
  end

  def install_consent_templates!
    Lakeraven::EHR::ConsentTemplate.install_defaults!
  end

  def post_handover(template_key: TEMPLATE_BH)
    send(:banner_request, :post, HANDOVER,
         { template_key: template_key, authenticity_token: csrf_token })
  end

  def post_kiosk_signature(extra = {})
    params = {
      signature: signature_data_url,
      signer_name: SYNTHETIC_SIGNER_NAME,
      authenticity_token: csrf_token
    }.merge(extra)
    send(:banner_request, :post, KIOSK, params)
  end

  def post_kiosk_unlock(access_code:, verify_code:)
    send(:banner_request, :post, KIOSK_UNLOCK,
         { access_code: access_code, verify_code: verify_code, authenticity_token: csrf_token })
  end

  def open_kiosk_via_handover!(template_key: TEMPLATE_BH)
    post_handover(template_key: template_key)
    follow_redirect!
    assert_equal KIOSK, URI.parse(request.url).path
  end

  def with_authentication_stub(result)
    service = Object.new
    service.define_singleton_method(:authenticate) { |**_kwargs| result }
    with_stub(Lakeraven::EHR::AuthenticationService, :new, service) { yield }
  end

  def auth_success_result(duz: DUZ)
    Lakeraven::EHR::AuthenticationService::Result.new(
      success?: true,
      error: nil,
      value: { duz: duz.to_s, name: "SYNTHETIC,CLINICIAN", user_type: "provider", security_keys: [], options: [] }
    )
  end

  def auth_failure_result(message = "Invalid access/verify code")
    Lakeraven::EHR::AuthenticationService::Result.new(success?: false, error: message, value: nil)
  end

  def auth_verify_must_change_result(duz: DUZ)
    Lakeraven::EHR::AuthenticationService::Result.new(
      success?: true,
      error: nil,
      value: {
        duz: duz.to_s,
        name: "SYNTHETIC,CLINICIAN",
        user_type: "provider",
        verify_needs_change: true,
        security_keys: [],
        options: []
      }
    )
  end

  def assert_cache_control_no_store!(message = nil)
    cache = response.headers["Cache-Control"].to_s
    assert_includes cache, "no-store", message || "expected Cache-Control to include no-store, got #{cache.inspect}"
  end

  def with_rpms_timed_read(seconds)
    auth = RpmsRpc::Authentication.singleton_class
    auth.alias_method(:__consent_timed_read, :timed_read)
    RpmsRpc::Authentication.define_singleton_method(:timed_read) { |_duz| seconds }
    yield
  ensure
    auth.alias_method(:timed_read, :__consent_timed_read)
    auth.remove_method(:__consent_timed_read)
  end

  def with_demo_visits_gate_open
    Lakeraven::EHR::DemoVisitsController.class_eval do
      alias_method :__consent_real_require_demo_mode!, :require_demo_mode!
      def require_demo_mode!; end
    end
    yield
  ensure
    Lakeraven::EHR::DemoVisitsController.class_eval do
      alias_method :require_demo_mode!, :__consent_real_require_demo_mode!
      remove_method :__consent_real_require_demo_mode!
    end
  end

  def capture_rails_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    previous = Rails.logger
    Rails.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous
  end

  def assert_locked_redirect_to_kiosk!(message = nil)
    assert_redirected_to(KIOSK, message)
  end

  def demo_patient_display_name
    "MARA DEMOPATIENT"
  end

  def demo_patient_dob_fragment
    "Jun 30, 1997"
  end
end
