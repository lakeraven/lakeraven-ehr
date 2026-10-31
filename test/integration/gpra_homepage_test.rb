# frozen_string_literal: true

require "test_helper"

# The signed-in homepage is the site's GPRA report (#780): tiles from the latest
# successful run, and each measure's care-gap patient list for a user who may run
# CRS patient lists.
class GpraHomepageTest < ActionDispatch::IntegrationTest
  BP = "crs-v25-controlling-high-blood-pressure"
  A1C_POOR = "crs-v25-diabetes-poor-glycemic-control"

  teardown { Lakeraven::EHR.configuration.gpra_targets = {} }

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "200", user_type: "user", user_name: "PROFILE,QI", security_keys: keys }
  end

  def measure(id, title, denominator, numerator, care_gaps: 0, notation: "increase")
    { "id" => id, "title" => title, "interpretation" => "", "improvement_notation" => notation,
      "denominator" => denominator, "numerator" => numerator,
      "rate" => denominator.zero? ? nil : (numerator.to_f / denominator).round(4), "care_gap_count" => care_gaps }
  end

  def make_run(status: "succeeded", finished_at: Time.utc(2026, 3, 1, 6), measures: [])
    Lakeraven::EHR::GpraRun.create!(period_start: Date.new(2025, 7, 1), period_end: Date.new(2026, 6, 30),
      status: status, started_at: finished_at - 600, finished_at: status == "running" ? nil : finished_at,
      error_class: status == "failed" ? "ArgumentError" : nil, measures: measures)
  end

  def tile(id) = css_select("[data-measure='#{id}']").first

  test "signing in lands on the homepage, and the header links there" do
    assert_equal "/lakeraven-ehr/", Lakeraven::EHR::Engine.routes.url_helpers.root_path
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_response :success
    assert_select "header a[href='/lakeraven-ehr/']", text: "Lakeraven EHR"
  end

  test "a user without BGPZMENU is sent to the dashboard" do
    sign_in("registration_menu")
    get "/lakeraven-ehr/"

    assert_redirected_to "/lakeraven-ehr/dashboard"
  end

  test "signed out, the homepage asks for sign-in" do
    get "/lakeraven-ehr/"

    assert_redirected_to "/lakeraven-ehr/login"
  end

  test "no run yet says so, with no numbers" do
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_select "#gpra-no-run"
    assert_select "#gpra-measures", count: 0
  end

  test "tiles show rate, counts and the as-of time of the latest successful run" do
    make_run(measures: [ measure(BP, "Controlling High Blood Pressure", 40, 30, care_gaps: 10) ])
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_select "time[datetime='2026-03-01T06:00:00Z']"
    assert_includes tile(BP).text, "75.0%"
    assert_includes tile(BP).text, "30 of 40 patients"
    assert_includes tile(BP).text, "Higher is better."
  end

  test "a measure with no patients shows no rate rather than 0%" do
    make_run(measures: [ measure(BP, "Controlling High Blood Pressure", 0, 0) ])
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_includes tile(BP).text, "No patients"
    refute_includes tile(BP).text, "0.0%"
  end

  test "a target is read the way the measure improves" do
    Lakeraven::EHR.configuration.gpra_targets = { BP => 0.7, A1C_POOR => 0.15 }
    make_run(measures: [ measure(BP, "BP", 40, 30), measure(A1C_POOR, "Poor A1c", 100, 20, notation: "decrease") ])
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_match(/Target 70.0%:\s+met/, tile(BP).css("[data-target]").text)
    assert_match(/Target 15.0%:\s+not met/, tile(A1C_POOR).css("[data-target]").text)
    assert_includes tile(A1C_POOR).text, "Lower is better."
  end

  test "the change since the previous run says whether it is better" do
    make_run(finished_at: Time.utc(2026, 2, 28, 6), measures: [ measure(BP, "BP", 40, 20), measure(A1C_POOR, "A1c", 100, 10, notation: "decrease") ])
    make_run(measures: [ measure(BP, "BP", 40, 30), measure(A1C_POOR, "A1c", 100, 20, notation: "decrease") ])
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_equal "better", tile(BP).css("[data-change]").attr("data-change").value
    assert_includes tile(BP).text, "Up 25.0 points"
    assert_equal "worse", tile(A1C_POOR).css("[data-change]").attr("data-change").value
  end

  test "a failed latest run is shown, above the last good report" do
    make_run(finished_at: Time.utc(2026, 2, 28, 6), measures: [ measure(BP, "BP", 40, 30) ])
    make_run(status: "failed", finished_at: Time.utc(2026, 3, 1, 6))
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_select "#gpra-latest-failed", text: /failed.*from the run before it/m
    assert_select "[data-measure='#{BP}']"
  end

  test "a failed run with no earlier good one shows no numbers" do
    make_run(status: "failed")
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"

    assert_select "#gpra-latest-failed"
    assert_select "#gpra-no-run"
    assert_select "#gpra-measures", count: 0
  end

  test "only a user with BGPZ PATIENT LISTS sees the care-gap link" do
    make_run(measures: [ measure(BP, "BP", 40, 30, care_gaps: 10) ])

    sign_in("quality_reports_user")
    get "/lakeraven-ehr/"
    assert_select "a[href='/lakeraven-ehr/gpra/measures/#{BP}/care_gaps']", count: 0
    assert_includes tile(BP).text, "10 patients with a care gap"

    sign_in("quality_reports_user,quality_reports_patient_lists")
    get "/lakeraven-ehr/"
    assert_select "a[href='/lakeraven-ehr/gpra/measures/#{BP}/care_gaps']", text: "10 patients with a care gap"
  end

  test "the care-gap list is refused without BGPZ PATIENT LISTS" do
    make_run(measures: [ measure(BP, "BP", 40, 30, care_gaps: 1) ])
    sign_in("quality_reports_user")
    get "/lakeraven-ehr/gpra/measures/#{BP}/care_gaps"

    assert_response :forbidden
  end

  test "the care-gap list names each patient from RPMS, with rook's reason" do
    run = make_run(measures: [ measure(BP, "Controlling High Blood Pressure", 40, 30, care_gaps: 1) ])
    run.care_gaps.create!(measure_id: BP, patient_dfn: "3", reason: "No blood pressure recorded in the measurement period")
    run.care_gaps.create!(measure_id: A1C_POOR, patient_dfn: "4", reason: "other measure")
    sign_in("quality_reports_patient_lists")

    with_brief_header(->(dfn) { dfn == 3 ? { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14) } : nil }) do
      get "/lakeraven-ehr/gpra/measures/#{BP}/care_gaps"
    end

    assert_response :success
    assert_select "#care-gaps tbody tr", count: 1
    assert_select "#care-gaps tr[data-dfn='3'] a[href='/lakeraven-ehr/patients/3']", text: "MOUSE,MICKEY M"
    assert_select "#care-gaps tr[data-dfn='3']", text: /14 Feb 1910.*No blood pressure recorded/m
  end

  test "a measure not in the latest run is not found" do
    make_run(measures: [ measure(BP, "BP", 40, 30) ])
    sign_in("quality_reports_patient_lists")
    get "/lakeraven-ehr/gpra/measures/no-such-measure/care_gaps"

    assert_response :not_found
  end

  private

  def with_brief_header(body)
    klass = RpmsRpc::Patient.singleton_class
    klass.alias_method(:__brief_header, :brief_header)
    klass.define_method(:brief_header, &body)
    yield
  ensure
    klass.alias_method(:brief_header, :__brief_header)
    klass.remove_method(:__brief_header)
  end
end
