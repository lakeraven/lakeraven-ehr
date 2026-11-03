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

  def self.rgb_png_bytes(width:, height:, &block)
    block ||= proc { |_x, _y| [ 255, 255, 255 ] }
    raw = (+"").tap do |rows|
      height.times do |y|
        rows << "\x00"
        width.times do |x|
          rows << block.call(x, y).pack("C*")
        end
      end
    end
    header = [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")
    PNG_MAGIC + png_chunk("IHDR", header) +
      png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
      png_chunk("IEND", "")
  end

  # At least twenty inked pixels that contrast with a transparent background.
  def self.visible_stroke_png(width: 50, height: 20)
    inked_png_bytes(width: width, height: height) do |x, y|
      x == y ? [ 0, 0, 0, 255 ] : [ 0, 0, 0, 0 ]
    end
  end

  def self.pad_sized_visible_signature_png
    inked_png_bytes(width: 600, height: 180) do |x, y|
      y == 90 && x.between?(50, 250) ? [ 0, 0, 0, 255 ] : [ 255, 255, 255, 0 ]
    end
  end

  # Small on the wire, large when decoded — one inked pixel on a 1414×1414 canvas.
  def self.oversized_compressible_signature_png
    w = h = 1414
    raw = (+"").b
    h.times do |y|
      if y == 700
        row = ("\x00".b * 2800) + "\x00\x00\x00\xFF".b + ("\x00".b * (w * 4 - 2804))
        raw << "\x00".b << row
      else
        raw << "\x00".b << ("\x00".b * (w * 4))
      end
    end
    header = [ w, h, 8, 6, 0, 0, 0 ].pack("NNCCCCC")
    PNG_MAGIC + png_chunk("IHDR", header) +
      png_chunk("IDAT", Zlib::Deflate.deflate(raw, 9)) +
      png_chunk("IEND", "")
  end

  def self.invisible_alpha_one_signature_png(width: 60, height: 20)
    inked_png_bytes(width: width, height: height) { |_x, _y| [ 0, 0, 0, 1 ] }
  end

  def self.near_white_rgb_signature_png(width: 50, height: 20)
    raw = (+"").b
    height.times do
      raw << "\x00".b << ("\xFF\xFF\xFF".b * width)
    end
    raw.setbyte(1, 0xFE)
    header = [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")
    PNG_MAGIC + png_chunk("IHDR", header) +
      png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
      png_chunk("IEND", "")
  end

  PAD_WIDTH = 600
  PAD_HEIGHT = 180

  def self.png_from_scanlines(width:, height:, color_type:, rows:)
    header = [ width, height, 8, color_type, 0, 0, 0 ].pack("NNCCCCC")
    PNG_MAGIC + png_chunk("IHDR", header) +
      png_chunk("IDAT", Zlib::Deflate.deflate(rows)) +
      png_chunk("IEND", "")
  end

  # Solid opaque white on an RGBA pad — no contrast with the page background.
  def self.blank_opaque_white_rgba_pad_png
    w, h = PAD_WIDTH, PAD_HEIGHT
    rows = (("\x00".b) + ("\xFF\xFF\xFF\xFF".b * w)) * h
    png_from_scanlines(width: w, height: h, color_type: 6, rows: rows)
  end

  # Grey+alpha solid opaque white (gray 255, alpha 255) — blank ink on white.
  def self.blank_opaque_white_graya_pad_png
    w, h = PAD_WIDTH, PAD_HEIGHT
    rows = (("\x00".b) + ("\xFF\xFF".b * w)) * h
    png_from_scanlines(width: w, height: h, color_type: 4, rows: rows)
  end

  # Near-white (#FEFEFE) fully opaque strokes on transparent paper.
  def self.near_white_ink_on_transparent_pad_png
    w, h = PAD_WIDTH, PAD_HEIGHT
    rows = (+"").b
    h.times do |y|
      rows << "\x00".b
      w.times do |x|
        rows << ((y == 90 && x < 300) ? "\xFE\xFE\xFE\xFF".b : "\x00\x00\x00\x00".b)
      end
    end
    png_from_scanlines(width: w, height: h, color_type: 6, rows: rows)
  end

  def self.dark_stroke_on_white_pad_png
    inked_png_bytes(width: PAD_WIDTH, height: PAD_HEIGHT) do |x, y|
      y == 90 && x.between?(50, 250) ? [ 0, 0, 0, 255 ] : [ 255, 255, 255, 255 ]
    end
  end

  def self.max_pad_dimension_signature_png(width: 1800, height: 600)
    inked_png_bytes(width: width, height: height) do |x, y|
      y == height / 2 && x.between?(50, 250) ? [ 0, 0, 0, 255 ] : [ 0, 0, 0, 0 ]
    end
  end

  def self.overwide_pad_signature_png
    max_pad_dimension_signature_png(width: 1801, height: 600)
  end

  def self.overtall_pad_signature_png
    max_pad_dimension_signature_png(width: 600, height: 601)
  end

  TINY_PNG = visible_stroke_png.freeze

  def magic_bytes_only_png
    PNG_MAGIC
  end

  def corrupt_truncated_png
    TINY_PNG.byteslice(0, 20)
  end

  def fully_transparent_signature_png
    ConsentWriteTestHelper.fully_transparent_png
  end

  def pad_sized_visible_signature_png
    ConsentWriteTestHelper.pad_sized_visible_signature_png
  end

  def oversized_compressible_signature_png
    ConsentWriteTestHelper.oversized_compressible_signature_png
  end

  def invisible_alpha_one_signature_png
    ConsentWriteTestHelper.invisible_alpha_one_signature_png
  end

  def near_white_rgb_signature_png
    ConsentWriteTestHelper.near_white_rgb_signature_png
  end

  def blank_opaque_white_rgba_pad_png
    ConsentWriteTestHelper.blank_opaque_white_rgba_pad_png
  end

  def blank_opaque_white_graya_pad_png
    ConsentWriteTestHelper.blank_opaque_white_graya_pad_png
  end

  def near_white_ink_on_transparent_pad_png
    ConsentWriteTestHelper.near_white_ink_on_transparent_pad_png
  end

  def dark_stroke_on_white_pad_png
    ConsentWriteTestHelper.dark_stroke_on_white_pad_png
  end

  def max_pad_dimension_signature_png(**kwargs)
    ConsentWriteTestHelper.max_pad_dimension_signature_png(**kwargs)
  end

  def overwide_pad_signature_png
    ConsentWriteTestHelper.overwide_pad_signature_png
  end

  def overtall_pad_signature_png
    ConsentWriteTestHelper.overtall_pad_signature_png
  end

  def with_second_handover_reaching_lock_write
    Lakeraven::EHR::ConsentsController.class_eval do
      alias_method :__consent_skip_locked_redirect, :redirect_when_consent_kiosk_locked
      def redirect_when_consent_kiosk_locked; end
    end
    yield
  ensure
    Lakeraven::EHR::ConsentsController.class_eval do
      alias_method :redirect_when_consent_kiosk_locked, :__consent_skip_locked_redirect
      remove_method :__consent_skip_locked_redirect
    end
  end

  def with_racing_kiosk_sign_loser
    Lakeraven::EHR::ConsentKioskController.class_eval do
      alias_method :__orig_stored_handover_signature, :stored_handover_signature
      def stored_handover_signature
        @signed_consent = nil
      end
    end
    yield
  ensure
    Lakeraven::EHR::ConsentKioskController.class_eval do
      alias_method :stored_handover_signature, :__orig_stored_handover_signature
      remove_method :__orig_stored_handover_signature
    end
  end

  def count_decode_signature_data_url_calls
    calls = 0
    singleton = Lakeraven::EHR::SignedConsent.singleton_class
    original = singleton.instance_method(:decode_signature_data_url)
    Lakeraven::EHR::SignedConsent.define_singleton_method(:decode_signature_data_url) do |value|
      calls += 1
      original.bind_call(Lakeraven::EHR::SignedConsent, value)
    end
    yield calls
  ensure
    singleton.send(:remove_method, :decode_signature_data_url)
    singleton.send(:define_method, :decode_signature_data_url, original)
  end

  def login_throttle_failures_for(access_code)
    key = Lakeraven::EHR::LoginThrottle.send(:key, access_code)
    Lakeraven::EHR::LoginThrottle.send(:attempts)[key]&.length.to_i
  end

  # Setup opens the kiosk first; clear server lock + session hint so POST handover
  # reaches ConsentsController#handover instead of redirecting to the kiosk.
  def reset_open_consent_kiosk_lock!
    session.delete(Lakeraven::EHR::ConsentKioskLock::SESSION_KEY)
    Lakeraven::EHR::KioskLock.delete_all
  end

  # Losing side of two concurrent handovers (see kiosk race probe): uniqueness
  # validation misses the winner row, then INSERT hits the unique index inside
  # the audit transaction.
  def with_handover_race_loser
    Lakeraven::EHR::KioskLock.define_singleton_method(:find_or_initialize_by) do |attrs|
      Lakeraven::EHR::KioskLock.insert!({
        credential_key: attrs[:credential_key],
        patient_dfn: DFN,
        template_key: TEMPLATE_BH,
        template_version: 1,
        handover_token: SecureRandom.uuid,
        created_at: Time.current,
        updated_at: Time.current
      })
      rec = Lakeraven::EHR::KioskLock.new(attrs)
      rec.define_singleton_method(:valid?) { |*| true }
      rec
    end
    yield
  ensure
    Lakeraven::EHR::KioskLock.singleton_class.send(:remove_method, :find_or_initialize_by)
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
    logger.level = Logger::DEBUG
    previous_rails = Rails.logger
    previous_ac = ActionController::Base.logger
    Rails.logger = logger
    ActionController::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous_rails
    ActionController::Base.logger = previous_ac
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
