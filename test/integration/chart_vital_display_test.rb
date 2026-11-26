# frozen_string_literal: true

require "test_helper"

# #976: the chart's Vital signs card shows units and names as a clinician
# reads them (98 °F, 117/81 mmHg, Pain), while the FHIR output keeps the
# UCUM codes. The stand-in answers RpmsRpc::Vital.for_patient (app logic only).
class ChartVitalDisplayTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  TAKEN = Time.new(2026, 9, 11, 21, 34)

  setup do
    setup_smart_auth(scopes: "system/*.read")
  end

  teardown do
    teardown_smart_auth
  end

  test "every vital type the chart maps shows a display unit and a readable name, and FHIR keeps UCUM" do
    rows = Lakeraven::EHR::Observation::VITAL_TYPE_MAP.keys.each_with_index.map do |type, i|
      { measurement_ien: 5000 + i, type: type, value: (type == "BP" ? "117/81" : "98"), recorded_date: TAKEN,
        display: nil, metric_display: nil, qualifiers: nil }
    end
    rows << { measurement_ien: 5100, type: "PA", value: "0", recorded_date: TAKEN,
              display: nil, metric_display: nil, qualifiers: nil }
    RpmsStandIn.answer(RpmsRpc::Vital, :for_patient, "1", with: rows)

    get "/lakeraven-ehr/patients/1", headers: @headers
    assert_response :success

    cards = Nokogiri::HTML(response.body).css("#chart-vitals [data-vital]")
    assert_equal rows.size, cards.size
    cards.each do |card|
      label = card.at_css("dt").text.strip
      unit = card.at_css("[data-vital-unit]").text.strip
      refute_includes unit, "[", "#{label} shows a UCUM code as its unit: #{unit.inspect}"
      # BMI is how clinicians name it; any other bare code is RPMS's, not a name.
      next if label == "BMI"

      refute_match(/\A[A-Z0-9]{1,4}\z/, label, "a vital is labelled with its RPMS code: #{label.inspect}")
    end

    shown = cards.to_h { |card| [ card.at_css("dt").text.strip, card.at_css("[data-vital-unit]").text.strip ] }
    assert_equal "°F", shown["Body Temperature"]
    assert_equal "mmHg", shown["Blood Pressure"]
    assert_equal "in", shown["Body Height"]
    assert_equal "lb", shown["Body Weight"]
    assert shown.key?("Pain"), "PA is labelled Pain: #{shown.keys.inspect}"

    get "/lakeraven-ehr/patients/1.json", headers: @headers
    temperature = JSON.parse(response.body)["entry"].map { |e| e["resource"] }.find do |r|
      r["resourceType"] == "Observation" && r.dig("code", "coding")&.any? { |c| c["code"] == "8310-5" }
    end
    assert_equal "[degF]", temperature.dig("valueQuantity", "code")
    assert_equal "[degF]", temperature.dig("valueQuantity", "unit")
  end
end
