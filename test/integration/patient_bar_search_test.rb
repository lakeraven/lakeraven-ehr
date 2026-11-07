# frozen_string_literal: true

require "test_helper"
require_relative "../support/patient_banner_test_helper"

# rpms-ux S-CHT-01: the patient bar's search and recent patients. RPMS is
# stood in for at the gem boundary with the shapes rpms-ydb 7c3119b answered
# (live_patient_bar_search_test.rb proves the same on a real broker).
class PatientBarSearchTest < ActionDispatch::IntegrationTest
  include PatientBannerTestHelper

  MOUSE = { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", mrn: "1001" }.freeze

  setup do
    enable_forgery_protection!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown do
    restore_forgery_protection!
    teardown_oauth!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  def with_rpms(find: ->(_text) { [ { dfn: 3, name: "MOUSE,MICKEY M" } ] })
    stubs = {
      RpmsRpc::PatientSelection.singleton_class => { find: find },
      RpmsRpc::Patient.singleton_class => { brief_header: ->(dfn) { dfn.to_i == 3 ? MOUSE : MOUSE.merge(name: "PATIENT,#{dfn}") } }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def search(q) = post("#{MOUNT}/chart_search", params: { q: q, authenticity_token: csrf_token })

  def opened(duz, dfn, at:)
    Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "E", outcome: "0", entity_type: "Patient",
                                       entity_identifier: dfn.to_s, agent_who_type: "Practitioner",
                                       agent_who_identifier: duz.to_s, created_at: at)
  end

  test "S-CHT-01.1 a match lists name, date of birth, sex and HRN, and opens the chart" do
    with_rpms do
      sign_in_clinician!
      get "#{MOUNT}/dashboard"
      search("MOUSE")

      assert_response :ok
      assert_select "#matches tr[data-dfn='3'] td", text: "MOUSE,MICKEY M"
      assert_select "#matches tr[data-dfn='3'] td", text: "Feb 14, 1910"
      assert_select "#matches tr[data-dfn='3'] td", text: "M"
      assert_select "#matches tr[data-dfn='3'] td", text: "1001"
      assert_select "#matches tr[data-dfn='3'] form[action$='/patients/3/context'][method='post']"
    end
  end

  test "a lookup RPMS refuses says the list is not complete, never no match" do
    with_rpms(find: ->(_text) { raise RpmsRpc::Client::RpcError, "refused" }) do
      sign_in_clinician!
      get "#{MOUNT}/dashboard"
      search("MOUSE")

      assert_response :service_unavailable
      assert_select "[role='alert']", text: /not complete/
      assert_select "#no-match", count: 0
    end
  end

  test "S-CHT-01.2 my recent patients are mine, newest first; another user's opens are not listed" do
    opened(DUZ, 1, at: 2.hours.ago)
    opened(DUZ, 3, at: 1.hour.ago)
    opened("12345", 2, at: 1.minute.ago)
    with_rpms do
      sign_in_clinician!
      get "#{MOUNT}/chart_search"

      assert_response :ok
      assert_equal %w[3 1], css_select("#recent-patients tbody tr").map { |tr| tr["data-dfn"] }
    end
  end

  test "a session that may not read patients is offered no search, and is refused one" do
    sign_in_clinician!(scopes: SCREENING_SCOPES)
    get "#{MOUNT}/dashboard"
    assert_select "#patient-banner form#patient-search", count: 0

    get "#{MOUNT}/chart_search"
    assert_response :forbidden
  end
end
