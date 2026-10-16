# frozen_string_literal: true

require "test_helper"

# HTML chart Age must be computed from filtered FHIR birthDate (egress bundle),
# not RPMS age or a days/365 approximation. Pins leap-year convention: Feb 29
# births treat Mar 1 as the birthday in non-leap years.
class ChartHtmlPatientAgeTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    setup_smart_auth(scopes: "system/*.read")
  end

  teardown do
    teardown_smart_auth
  end

  test "HTML chart Age is 45 on the day before the patient's birthday" do
    travel_to Time.zone.local(2026, 5, 14, 12, 0, 0) do
      get_chart_html
      assert_chart_age "45"
    end
  end

  test "HTML chart Age is 46 on the patient's birthday, not the seeded RPMS age" do
    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      get_chart_html
      assert_chart_age "46"
      refute_equal "45", chart_age_dd_text,
                   "must not show unfiltered RPMS age when birthDate is present in the egress bundle"
    end
  end

  test "HTML chart Age for Feb 29 birthDate uses Mar 1 as birthday in non-leap years" do
    travel_to Time.zone.local(2026, 2, 28, 12, 0, 0) do
      with_patient_birth_date_in_egress_bundle("2000-02-29") { get_chart_html }
      assert_chart_age "25"
    end

    travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
      with_patient_birth_date_in_egress_bundle("2000-02-29") { get_chart_html }
      assert_chart_age "26"
    end
  end

  test "HTML chart shows em dash for Age when egress bundle birthDate is after today" do
    travel_to Time.zone.local(2026, 10, 16, 12, 0, 0) do
      with_patient_birth_date_in_egress_bundle("2026-12-01") { get_chart_html }
      assert_chart_age "—"
    end
  end

  test "HTML chart shows em dash for Age and DOB when egress bundle omits birthDate" do
    with_egress_bundle_after_filter(->(payload) {
      next payload unless payload.is_a?(Hash)

      bundle = payload.deep_dup.deep_stringify_keys
      patient_entry = bundle["entry"]&.find { |e| e.dig("resource", "resourceType") == "Patient" }
      patient_entry["resource"].delete("birthDate") if patient_entry
      bundle
    }) do
      get_chart_html
    end

    assert_response :ok
    assert_chart_age "—"
    assert_chart_dob "—"
    refute_includes chart_dob_dd_text.to_s, "1980"
    refute_includes chart_dob_dd_text.to_s, "May"
  end

  private

  def get_chart_html
    get "/lakeraven-ehr/patients/1", headers: @headers
  end

  def assert_chart_age(expected)
    assert_response :ok
    assert_equal expected, chart_age_dd_text,
                 "Expected Age <dd> to show #{expected.inspect}, got #{chart_age_dd_text.inspect}"
  end

  def assert_chart_dob(expected)
    assert_equal expected, chart_dob_dd_text
  end

  def chart_age_dd_text
    demoinfo_dd_for("Age")
  end

  def chart_dob_dd_text
    demoinfo_dd_for("DOB")
  end

  def demoinfo_dd_for(label)
    html = Nokogiri::HTML(response.body)
    block = html.css("dl.demoinfo div").find { |div| div.at_css("dt")&.text == label }
    block&.at_css("dd")&.text&.strip
  end

  def with_patient_birth_date_in_egress_bundle(birth_date)
    with_egress_bundle_after_filter(->(payload) {
      next payload unless payload.is_a?(Hash)

      bundle = payload.deep_dup.deep_stringify_keys
      patient_entry = bundle["entry"]&.find { |e| e.dig("resource", "resourceType") == "Patient" }
      patient_entry["resource"]["birthDate"] = birth_date if patient_entry
      bundle
    }) { yield }
  end

  def with_egress_bundle_after_filter(transform)
    filter = Lakeraven::EHR::Part2EgressFilter.singleton_class
    original = filter.instance_method(:call)
    filter.define_method(:call) do |payload|
      result = original.bind(Lakeraven::EHR::Part2EgressFilter).call(payload)
      transform.call(result)
    end
    yield
  ensure
    filter.define_method(:call, original)
  end
end
