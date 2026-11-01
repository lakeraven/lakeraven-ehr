# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-CHT-01): the physician signs in through the login form and
# finds the build's demo patient MOUSE,MICKEY M (DFN 3, HRN 1001, born
# 1910-02-14, SSN ending 9999) from the patient bar, by each thing a clinician
# may have in hand, then opens the chart and sees them in recent patients.
# Every request is a form on the page, posted with that form's token.
# Skipped unless LIVE_RPMS=1 (see test_helper.rb), e.g.
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9130 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_patient_bar_search_test.rb
class LivePatientBarSearchTest < ActionDispatch::IntegrationTest
  BAR_SEARCH = "#patient-banner form#patient-search"

  setup do
    skip "live: set LIVE_RPMS=1 and a broker" unless defined?(LIVE_RPMS) && LIVE_RPMS
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  # One process holds one broker identity (rpms-rpc#234).
  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_was unless @forgery_was.nil?
    LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS
  end

  def submit(selector, params = {})
    form = Nokogiri::HTML(response.body).at_css(selector) or flunk("no form #{selector}")
    token = form.at_css("input[name='authenticity_token']")&.[]("value")
    post form["action"], params: params.merge(authenticity_token: token)
  end

  def sign_in_physician
    get "/lakeraven-ehr/login"
    submit("form[action$='/login']", username: "PMD123", password: "PMD123!!")
    follow_redirect!
  end

  test "S-CHT-01.1 the physician finds the patient by name, HRN, date of birth and last four, never seeing the SSN" do
    sign_in_physician
    assert_select BAR_SEARCH

    [ "MOUSE", "1001", "2/14/1910", "9999", "M9999" ].each do |typed|
      submit(BAR_SEARCH, q: typed)

      assert_response :ok
      assert_select "#matches tr[data-dfn='3'] td", text: "MOUSE,MICKEY M"
      assert_select "#matches tr[data-dfn='3'] td", text: "Feb 14, 1910"
      assert_select "#matches tr[data-dfn='3'] td", text: "1001"
      assert_no_match(/\d{3}-?\d{2}-?9999/, response.body, "the SSN must not appear (#{typed})")
    end

    submit(BAR_SEARCH, q: "ZZZNOBODY")
    assert_select "#no-match"
  end

  test "S-CHT-01.2 a patient the physician opens is listed first in their recent patients" do
    sign_in_physician
    submit(BAR_SEARCH, q: "MOUSE")
    submit("#matches tr[data-dfn='3'] form")
    assert_redirected_to "/lakeraven-ehr/patients/3"
    follow_redirect!
    assert_response :ok
    assert_select "h1", text: /Mouse|MOUSE/

    get "/lakeraven-ehr/chart_search"
    assert_response :ok
    assert_select "#recent-patients tbody tr:first-child[data-dfn='3']"
  end
end
