# frozen_string_literal: true

require "test_helper"
require_relative "../support/progress_note_test_helper"

# A page with the patient banner has one <h1>, the page's own (#1113), so a
# screen reader user hears one page title. The banner names the patient
# without a heading: it is on every page with a patient open, so it is never
# what the page is about.
class OnePageHeadingTest < ActionDispatch::IntegrationTest
  include ProgressNoteTestHelper

  DFN = "1"
  PATIENT_NAME = "Alice Anderson"
  # A clinician who can record allergies and chart a visit, so the chart and
  # the allergy form render everything they offer.
  KEYS = %w[provider].freeze
  SCOPES = "#{PatientBannerTestHelper::BANNER_SCOPES} user/Consent.read".freeze

  # Every page here renders the banner for the open patient.
  PAGES = {
    "the dashboard" => "#{MOUNT}/dashboard",
    "the chart" => "#{MOUNT}/patients/#{DFN}",
    "the screenings" => "#{MOUNT}/patients/#{DFN}/screenings",
    "the consents" => "#{MOUNT}/patients/#{DFN}/consents",
    "the allergy form" => "#{MOUNT}/patients/#{DFN}/allergies/new",
    "the notifications" => "#{MOUNT}/notifications"
  }.freeze

  setup do
    enable_forgery_protection!
  end

  teardown do
    restore_forgery_protection!
    teardown_oauth!
  end

  def open_patient!
    sign_in_with_keys!(KEYS, scopes: SCOPES)
    open_patient_context!(DFN)
  end

  def assert_one_h1_and_the_banner!(label)
    assert_select "#patient-banner", { text: /#{PATIENT_NAME}/ }, "#{label}: the banner names the patient"
    assert_select "#patient-banner h1", { count: 0 }, "#{label}: the banner's name is not a heading"
    assert_select "h1", { count: 1 }, "#{label}: one h1"
    assert_select "main h1", { count: 1 }, "#{label}: the h1 is the page's own"
  end

  PAGES.each do |label, path|
    test "#{label} has one h1 under the patient banner" do
      with_demo_clinical_seeds do
        open_patient!
        get path

        assert_response :ok
        assert_one_h1_and_the_banner!(label)
      end
    end
  end

  test "the page that says RPMS did not answer has one h1 under the patient banner" do
    with_demo_clinical_seeds do
      open_patient!
      restore = StubHelpers.send(:singleton_method_restore, Lakeraven::EHR::NotificationsGateway, :inbox)
      Lakeraven::EHR::NotificationsGateway.define_singleton_method(:inbox) do |*_args, **_kwargs|
        raise RpmsRpc::Error, "SYNTHETIC broker failure"
      end
      begin
        get "#{MOUNT}/notifications"
      ensure
        restore.call
      end

      assert_response :service_unavailable
      assert_select "#rpms-unavailable"
      assert_one_h1_and_the_banner!("RPMS unavailable")
    end
  end
end
