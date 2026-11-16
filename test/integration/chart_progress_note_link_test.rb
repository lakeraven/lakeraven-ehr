# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"
require_relative "../support/progress_note_test_helper"

# The chart's way into writing a progress note (#1001). The "Encounters &
# Appointments" card links to the note form when the site has a note title
# configured and the signed-in user holds the PROVIDER key, and shows no such
# link otherwise. It no longer links to the demo's walk-in page, which answers
# 404 everywhere but the development demo.
class ChartProgressNoteLinkTest < ActionDispatch::IntegrationTest
  include ProgressNoteTestHelper

  DFN = "3"
  CHART = "/lakeraven-ehr/patients/#{DFN}"
  NEW_NOTE = "#{CHART}/notes/new"
  DEMO_VISIT = "#{CHART}/visits/new"
  NON_PROVIDER_KEYS = %w[orders_sign orders_enter scheduling_user registration_menu].freeze

  setup do
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @demo_original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was
    restore_progress_note_title!
    teardown_oauth!
    if @demo_original_client
      RpmsRpc.configure { |c| c.client = @demo_original_client }
      @demo_original_client = nil
    end
  end

  def open_chart_as(keys, title:)
    configure_progress_note_title!(title)
    sign_in_with_keys!(keys)
    open_patient_context!(DFN)
    get CHART
    assert_response :ok
    assert_select "h2", text: /Encounters/
  end

  def links_to(path) = css_select("a[href='#{path}']")

  test "a provider sees a link to write a note when a note title is configured" do
    open_chart_as(%w[provider], title: TITLE_IEN)

    links = links_to(NEW_NOTE)
    assert_equal 1, links.size, "one link to the note form"
    assert_match(/note/i, links.first.text)
  end

  test "the link to write a note is in the Encounters and Appointments card" do
    open_chart_as(%w[provider], title: TITLE_IEN)

    link = links_to(NEW_NOTE).first
    assert link, "a link to the note form"
    heading = link.ancestors.lazy.filter_map { |node| node.css("h2").first }.first
    assert heading, "the link sits under a card heading"
    assert_match(/Encounters/, heading.text)
  end

  test "a provider who also holds other keys sees the link" do
    open_chart_as(%w[provider orders_sign referrals_user], title: TITLE_IEN)

    assert_equal 1, links_to(NEW_NOTE).size
  end

  test "the chart shows no link to write a note when no note title is configured" do
    open_chart_as(%w[provider], title: nil)

    assert_empty links_to(NEW_NOTE)
    assert_empty links_to(DEMO_VISIT), "and no link to a page that answers 404"
  end

  test "the chart shows no link to write a note when the title is not a positive integer" do
    open_chart_as(%w[provider], title: "abc")

    assert_empty links_to(NEW_NOTE)
    assert_empty links_to(DEMO_VISIT)
  end

  test "the chart shows no link to write a note to a user without the PROVIDER key" do
    open_chart_as(NON_PROVIDER_KEYS, title: TITLE_IEN)

    assert_empty links_to(NEW_NOTE)
    assert_empty links_to(DEMO_VISIT), "and no link to a page that answers 404"
  end

  test "the chart never links to the demo walk-in page outside the development demo" do
    open_chart_as(%w[provider], title: TITLE_IEN)

    assert_empty links_to(DEMO_VISIT)
    assert_select "a[href*=?]", "/visits/new", count: 0
    assert_no_match(/\+ New visit/, response.body)
  end

  test "the chart opened with a bearer token and no session shows neither link" do
    configure_progress_note_title!(TITLE_IEN)
    setup_chart_bearer!

    get CHART, headers: @chart_headers

    assert_response :ok
    assert_empty links_to(NEW_NOTE), "no session keys, so no capability"
    assert_empty links_to(DEMO_VISIT)
  end

  test "the link the chart shows leads to the note form" do
    open_chart_as(%w[provider], title: TITLE_IEN)
    link = links_to(NEW_NOTE).first
    assert link, "a link to the note form"

    tiu = FakeTiu.new(visits_by_dfn: { DFN => [ open_visit_row ] })
    with_fake_tiu(tiu) { get link["href"] }

    assert_response :ok
    assert_select "textarea[name=?]", "note_text"
  end
end
