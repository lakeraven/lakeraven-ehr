# frozen_string_literal: true

require "test_helper"

# #722, rpms-ux S-REG-01 and S-REG-02: a patient's SSN, name and date of birth
# never travel in a URL (and so never reach browser history or an access log),
# and the engine keeps them out of its own logs.
class RegistrationPhiOutOfUrlsTest < ActionDispatch::IntegrationTest
  SSN = "123-45-6789"

  def sign_in
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG",
                                                  security_keys: "registration_menu" }
  end

  def with_lookup
    gateway = Lakeraven::EHR::PatientLookupGateway
    asked = []
    gateway.singleton_class.alias_method(:__find, :find)
    gateway.define_singleton_method(:find) { |text, dob: nil, **| asked << [ text, dob ] and [] }
    yield asked
  ensure
    gateway.singleton_class.alias_method(:find, :__find)
    gateway.singleton_class.remove_method(:__find)
  end

  test "the search form posts, and a search by SSN never puts it in a URL" do
    sign_in
    get "/lakeraven-ehr/registration/patients"
    form = css_select("form").find { |f| f.at_css("input[name='q']") }
    assert_equal "post", form["method"]
    assert_equal "/lakeraven-ehr/registration/patients/search", form["action"]

    with_lookup do |asked|
      post "/lakeraven-ehr/registration/patients/search", params: { q: SSN }
      assert_response :ok
      assert_equal [ [ SSN, nil ] ], asked
      refute_includes request.fullpath, "6789"
    end
  end

  test "a search carried in a URL is not run" do
    sign_in
    with_lookup do |asked|
      get "/lakeraven-ehr/registration/patients", params: { q: SSN }
      assert_response :ok
      assert_empty asked, "a GET search would put the SSN in browser history and access logs"
    end
  end

  test "the tribe and community look-ups post the form back, never resubmit it by GET" do
    sign_in
    get "/lakeraven-ehr/registration/patients/new"
    assert_response :ok
    lookups = css_select("form [formaction]")
    refute_empty lookups
    assert(lookups.all? { |b| b["formmethod"] == "post" }, "a look-up resubmits the demographics by GET")
    assert_empty css_select("form[method='get'] input[name*='ssn']")
  end

  test "after an unknown outcome the search is offered as a post, not a link carrying the name" do
    html = Lakeraven::EHR::Registration::PatientsController.render(
      template: "lakeraven/ehr/registration/patients/outcome_unknown",
      assigns: { registration: Struct.new(:name, :dob).new("PROBE,ALPHA", Date.new(1990, 5, 1)) },
      layout: false
    )
    doc = Nokogiri::HTML(html)
    assert_empty doc.css("a[href*='PROBE'], a[href*='1990']")
    button = doc.at_css("#search-after-unknown")
    assert button, "the search after an unknown outcome is offered"
    assert_equal "post", button.ancestors("form").first["method"]
  end

  test "the engine filters a patient's identity from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("q" => SSN, "dob" => "1990-05-01", "registration" => { "ssn" => SSN, "name" => "PROBE,ALPHA" },
                             "request_id" => "keep-me")

    assert_equal "[FILTERED]", filtered["q"]
    assert_equal "[FILTERED]", filtered["dob"]
    assert_equal "[FILTERED]", filtered["registration"]
    assert_equal "keep-me", filtered["request_id"], "q is matched exactly, not as any key containing a q"
  end
end
