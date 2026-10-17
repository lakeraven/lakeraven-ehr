# frozen_string_literal: true

require "nokogiri"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Shared helpers for persistent patient banner specification tests (#466).
module PatientBannerTestHelper
  MOUNT = "/lakeraven-ehr"
  DUZ = "99999"
  SCREENING_SCOPES = "user/QuestionnaireResponse.read user/QuestionnaireResponse.write"
  CHART_SCOPES = "system/*.read"
  BANNER_SCOPES = [
    "user/Patient.read",
    "user/AllergyIntolerance.read",
    "user/Condition.read",
    "user/MedicationRequest.read",
    "user/Observation.read",
    "user/QuestionnaireResponse.read",
    "user/QuestionnaireResponse.write"
  ].join(" ")

  def enable_forgery_protection!
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  def restore_forgery_protection!
    return if @forgery_was.nil?

    ActionController::Base.allow_forgery_protection = @forgery_was
    @forgery_was = nil
  end

  def with_demo_clinical_seeds
    @demo_original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    yield
  ensure
    RpmsRpc.configure { |c| c.client = @demo_original_client } if @demo_original_client
    @demo_original_client = nil
  end

  def clinician_token(scopes:, app_name: Lakeraven::EHR::SmartAuthentication::BROWSER_SSO_APP_NAME, duz: DUZ)
    app = Doorkeeper::Application.create!(
      name: app_name, redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: scopes, resource_owner_id: duz, expires_in: 3600
    )
    if app_name == Lakeraven::EHR::SmartAuthentication::BROWSER_SSO_APP_NAME && token.has_attribute?(:browser_session)
      token.update_column(:browser_session, true)
    end
    token
  end

  def sign_in_clinician!(scopes: BANNER_SCOPES, duz: DUZ)
    @clinician_token = clinician_token(scopes: scopes, duz: duz)
    post "#{MOUNT}/test_session",
         params: {
           duz: duz, user_type: "provider",
           smart_token: @clinician_token.plaintext_token || @clinician_token.token
         }
    @csrf_token = nil
  end

  def current_response
    if respond_to?(:response) && !response.nil?
      response
    else
      last_response
    end
  end

  def html_response_body
    current_response.body
  end

  def follow_redirect_if_needed!
    follow_redirect! if current_response.redirect?
  end

  def csrf_token
    @csrf_token ||= begin
      get "#{MOUNT}/login"
      html_response_body[/name="csrf-token" content="([^"]+)"/, 1]
    end
  end

  def open_patient_context!(dfn)
    post "#{MOUNT}/patients/#{dfn}/context", params: { authenticity_token: csrf_token }
    follow_redirect_if_needed!
  end

  def bearer_headers(token = nil)
    token ||= @chart_token
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def setup_chart_bearer!(scopes: CHART_SCOPES)
    @chart_token = clinician_token(
      scopes: scopes,
      app_name: "chart-spec",
      duz: nil
    )
    @chart_headers = bearer_headers(@chart_token)
  end

  def teardown_oauth!
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
  end

  def patient_banner_node
    Nokogiri::HTML(html_response_body).at_css("#patient-banner")
  end

  def allergies_field_node
    patient_banner_node&.at_css("[data-allergies-state]")
  end

  def assert_patient_banner!
    node = patient_banner_node
    assert node, "Expected #patient-banner on the page"
    node
  end

  def assert_banner_sticky_stylesheet!
    css_path = Lakeraven::EHR::Engine.root.join(
      "app/assets/stylesheets/lakeraven/ehr/application.css"
    )
    css = File.read(css_path)
    banner = patient_banner_node
    inline_sticky = banner["style"].to_s.match?(/position:\s*sticky/i)
    class_sticky = banner["class"].to_s.match?(/sticky/i)
    sheet_sticky = css.match?(/#patient-banner[^{]*\{[^}]*position:\s*sticky/i)

    assert inline_sticky || class_sticky || sheet_sticky,
           "Expected #patient-banner to be sticky via class, inline style, or application.css"
  end

  def assert_banner_demographics!(name:, mrn:, dob:, age:, sex:)
    banner = assert_patient_banner!
    text = banner.text
    assert_includes text, name, "banner name"
    assert_includes text, mrn.to_s, "banner MRN/HRN"
    assert_includes text, dob, "banner DOB"
    assert_includes text, age.to_s, "banner age"
    assert_includes text, sex, "banner sex"
  end

  def assert_allergies_state!(state, text_fragment: nil)
    field = allergies_field_node
    assert field, "Expected allergies field inside #patient-banner"
    assert_equal state, field["data-allergies-state"]
    assert_includes field.text, text_fragment if text_fragment
  end

  def assert_empty_banner!
    banner = assert_patient_banner!
    assert_includes banner.text, "No patient selected"
    link = banner.css("a").find { |a| a.text.match?(/chart search/i) }
    assert link, "Expected a chart search link in the empty banner"
    assert link["href"].present?, "Chart search link must have an href"
  end

  def submit_clear_patient_context!
    banner = assert_patient_banner!
    form = banner.at_css("form") ||
           Nokogiri::HTML(html_response_body).css("#patient-banner form").first
    assert form, "Expected a form for Clear patient context inside #patient-banner"

    action = form["action"].to_s
    action = "#{MOUNT}#{action}" if action.start_with?("/")

    params = {}
    form.css("input").each do |input|
      next if input["name"].blank?

      params[input["name"]] = input["value"]
    end
    params["authenticity_token"] = csrf_token if params["authenticity_token"].blank?

    method = form.at_css('input[name="_method"]')&.[]("value") || form["method"] || "post"
    case method.to_s.downcase
    when "delete"
      delete action, params: params
    when "patch"
      patch action, params: params
    else
      post action, params: params
    end
    follow_redirect_if_needed!
  end

  def with_allergy_source_raising
    klass = Lakeraven::EHR::SupplementalClinicalResources
    original = klass.method(:merged_allergy_intolerances_for_patient)
    klass.define_singleton_method(:merged_allergy_intolerances_for_patient) do |_dfn|
      raise StandardError, "allergy source unavailable"
    end
    yield
  ensure
    klass.define_singleton_method(:merged_allergy_intolerances_for_patient, original)
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

  def strip_allergy_intolerances_from_bundle(payload)
    return payload unless payload.is_a?(Hash)

    bundle = payload.deep_dup.deep_stringify_keys
    bundle["entry"]&.reject! { |e| e.dig("resource", "resourceType") == "AllergyIntolerance" }
    bundle
  end
end
