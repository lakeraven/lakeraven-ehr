# frozen_string_literal: true

require_relative "patient_banner_test_helper"

# Shared helpers for the progress-note-from-chart specification (#1001).
#
# The fakes stand at the gateway class methods the flow is specified to reach
# (EncounterGateway.visits, ProgressNoteGateway.create / update_text,
# ESignatureGateway.validate / add) and answer in the shapes the real gateways
# answer in: validate is a boolean, the others are hashes.
module ProgressNoteTestHelper
  include PatientBannerTestHelper

  MOUNT = PatientBannerTestHelper::MOUNT
  DUZ = PatientBannerTestHelper::DUZ

  TITLE_ENV = "PROGRESS_NOTE_TITLE_IEN"
  TITLE_IEN = 1234
  NOTE_IEN = 7001

  SYNTHETIC_NOTE_TEXT = "SYNTHETIC-NOTE-BODY line one"
  SYNTHETIC_SIGNATURE_CODE = "SYNTH-SIG-CODE-1001"
  SYNTHETIC_BROKER_MESSAGE = "SYNTHETIC-BROKER-TEXT-1001"

  OPEN_VISIT_IEN = 501
  LOCKED_VISIT_IEN = 502
  OTHER_PATIENT_VISIT_IEN = 601
  OPEN_LOCATION = "SYNTHETIC CLINIC A"
  LOCKED_LOCATION = "SYNTHETIC CLINIC B"

  def open_visit_row(visit_ien: OPEN_VISIT_IEN, location: OPEN_LOCATION)
    { visit_ien: visit_ien, location_ien: 11, location: location, service_category: "A",
      category: "AMBULATORY", datetime: Time.zone.local(2026, 11, 10, 9, 30), locked: false,
      provider_ien: DUZ.to_i, provider: "SYNTHETIC,PROVIDER", standalone: false }
  end

  def locked_visit_row(visit_ien: LOCKED_VISIT_IEN, location: LOCKED_LOCATION)
    open_visit_row(visit_ien: visit_ien, location: location)
      .merge(datetime: Time.zone.local(2026, 11, 3, 14, 15), locked: true)
  end

  # Records every gateway call, in order, as [name, args, kwargs].
  class FakeTiu
    attr_reader :calls

    # visits_by_dfn: { "3" => [rows] }. An Exception in `raises[name]` is
    # raised by that call after it is recorded.
    def initialize(visits_by_dfn:, validate: true,
                   create: { success: true, ien: NOTE_IEN, raw: NOTE_IEN.to_s },
                   update_text: { success: true, raw: NOTE_IEN.to_s },
                   add: { success: true, raw: "0" },
                   raises: {})
      @visits_by_dfn = visits_by_dfn.transform_keys(&:to_s)
      @returns = { validate: validate, create: create, update_text: update_text, add: add }
      @raises = raises
      @calls = []
    end

    def call(name, args, kwargs = {})
      @calls << [ name, args, kwargs ]
      raise @raises[name] if @raises[name]
      return @visits_by_dfn.fetch(args.first.to_s, []) if name == :visits

      @returns.fetch(name)
    end

    def calls_to(name) = @calls.select { |call| call.first == name }
    def names = @calls.map(&:first)

    # Everything but the visit read: the e-signature check and the TIU writes.
    def write_side_calls = @calls.reject { |call| call.first == :visits }

    # What reaches the TIU document: create, text, sign.
    def tiu_calls = @calls.select { |call| %i[create update_text add].include?(call.first) }
  end

  FAKED_GATEWAY_METHODS = [
    [ "Lakeraven::EHR::EncounterGateway", :visits ],
    [ "Lakeraven::EHR::ProgressNoteGateway", :create ],
    [ "Lakeraven::EHR::ProgressNoteGateway", :update_text ],
    [ "Lakeraven::EHR::ESignatureGateway", :validate ],
    [ "Lakeraven::EHR::ESignatureGateway", :add ]
  ].freeze

  def with_fake_tiu(fake)
    restores = FAKED_GATEWAY_METHODS.map do |class_name, method_name|
      klass = class_name.constantize
      restore = StubHelpers.send(:singleton_method_restore, klass, method_name)
      klass.define_singleton_method(method_name) { |*args, **kwargs| fake.call(method_name, args, kwargs) }
      restore
    end
    yield
  ensure
    Array(restores).reverse_each { |restore| restore&.call }
  end

  # The title is read from ENV when the configuration is built, so each
  # setting builds a new configuration. restore_progress_note_title! puts
  # both back.
  def configure_progress_note_title!(value)
    @progress_note_title_env_was = ENV[TITLE_ENV] unless defined?(@progress_note_title_env_saved)
    @progress_note_title_env_saved = true
    value.nil? ? ENV.delete(TITLE_ENV) : ENV[TITLE_ENV] = value.to_s
    Lakeraven::EHR.reset_configuration!
  end

  def restore_progress_note_title!
    return unless defined?(@progress_note_title_env_saved)

    @progress_note_title_env_was.nil? ? ENV.delete(TITLE_ENV) : ENV[TITLE_ENV] = @progress_note_title_env_was
    Lakeraven::EHR.reset_configuration!
  end

  # A browser session as sign-on leaves it: a DUZ, the security keys RPMS
  # reported (by their Roles names), and the session's SMART token, which the
  # chart and the patient-context POST read.
  def sign_in_with_keys!(keys, duz: DUZ, scopes: PatientBannerTestHelper::BANNER_SCOPES)
    @clinician_token = clinician_token(scopes: scopes, duz: duz)
    post "#{MOUNT}/test_session", params: {
      duz: duz, user_type: "provider", security_keys: Array(keys).join(","),
      smart_token: @clinician_token.plaintext_token || @clinician_token.token
    }
    @csrf_token = nil
  end

  # Rails.logger and the controllers' own logger, which is where the request
  # parameters are written.
  def capture_request_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    rails_was = Rails.logger
    controller_was = ActionController::Base.logger
    Rails.logger = logger
    ActionController::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger = rails_was
    ActionController::Base.logger = controller_was
  end
end
