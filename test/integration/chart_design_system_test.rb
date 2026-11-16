# frozen_string_literal: true

require "test_helper"
require_relative "../support/progress_note_test_helper"

# The chart is built from the design-system pieces the rest of the app uses
# (docs/DESIGN-SYSTEM.md), not from CSS of its own scoped to .chart-page
# (#1111). Since the chart moved into the app layout (#979) that scoped CSS
# could not reach the banner, so the banner's allergy actions and the chart's
# sections looked unlike the pages around them.
class ChartDesignSystemTest < ActionDispatch::IntegrationTest
  include ProgressNoteTestHelper

  DFN = "1"
  CHART = "#{MOUNT}/patients/#{DFN}".freeze
  # PROVIDER holds allergy.record, so the banner offers its allergy actions.
  KEYS = %w[provider].freeze

  setup { enable_forgery_protection! }

  teardown do
    restore_forgery_protection!
    restore_progress_note_title!
    teardown_oauth!
  end

  def open_chart!
    configure_progress_note_title!(TITLE_IEN)
    sign_in_with_keys!(KEYS)
    open_patient_context!(DFN)
    get CHART
    assert_response :ok
  end

  test "the chart page carries no style block and no inline styles of its own" do
    with_demo_clinical_seeds do
      open_chart!

      assert_empty css_select("style").select { |style| style.text.include?("chart-") },
        "no chart-scoped style block"
      assert_select ".chart-page", count: 0
      assert_select "main [style]", count: 0
    end
  end

  test "each chart section is a card with a heading and a data table" do
    with_demo_clinical_seeds do
      open_chart!

      %w[problems medications vitals screenings allergies encounters].each do |id|
        assert_select "main section#chart-#{id}.card h2", { count: 1 }, "#{id}: a card with one heading"
      end
      tables = css_select("main section.card table")
      refute_empty tables
      tables.each do |table|
        assert_includes table["class"].to_s.split, "data-table", "#{table['id']}: a data-table"
        assert table.at_css("caption"), "#{table['id']}: a caption"
        assert table.css("th").all? { |th| th["scope"] == "col" }, "#{table['id']}: th scope=col"
      end
    end
  end

  test "statuses are status badges, and an empty section says so with empty_state" do
    with_demo_clinical_seeds do
      open_chart!

      assert_select "#chart-problems td [data-status-badge].status-badge"
      assert_select "#chart-medications td [data-status-badge].status-badge"
      assert_select "#chart-screenings .empty-state", text: /No screenings recorded\./
    end
  end

  test "the chart's actions are page_header actions with the app's buttons" do
    with_demo_clinical_seeds do
      open_chart!

      assert_select ".page-header .page-header__actions a.button-secondary", text: "Consents"
      assert_select "#chart-encounters a.button-primary[href=?]", "#{CHART}/notes/new", text: "Write note"
    end
  end

  test "the banner's allergy actions use the app's secondary button" do
    with_demo_clinical_seeds do
      open_chart!

      actions = "#patient-banner .patient-banner__allergy-actions"
      assert_select "#{actions} a.button-secondary", text: "Record an allergy"
      assert_select "#{actions} button.button-secondary", text: "No known allergies"
    end
  end
end
