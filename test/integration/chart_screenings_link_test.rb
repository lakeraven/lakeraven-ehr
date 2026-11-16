# frozen_string_literal: true

require "test_helper"

# The chart links to the patient's screenings (rpms-ux S-VIS-09.1, staff
# walkthrough gap 12), so a clinician no longer types the address. The link
# shows only to a user whose sign-on may read screenings: the scope the
# behavioral health keys grant (SessionScopePolicy), which is the same check
# the screenings page itself makes.
class ChartScreeningsLinkTest < ActionDispatch::IntegrationTest
  CHART_OPTION = [ "CIAV VUECENTRIC" ].freeze

  teardown do
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
  end

  test "S-VIS-09.1 a clinician holding the behavioral health key reaches the patient's screenings from the chart" do
    get "/lakeraven-ehr/patients/1", headers: signed_on_as(%i[behavioral_health_user])

    assert_response :ok
    assert_select "a[href='/lakeraven-ehr/patients/1/screenings']", text: "Screenings"
  end

  test "S-VIS-09.1 a medical assistant without the behavioral health key is not offered the screenings link" do
    get "/lakeraven-ehr/patients/1", headers: signed_on_as(%i[orders_enter])

    assert_response :ok
    assert_select "a[href='/lakeraven-ehr/patients/1/screenings']", count: 0
  end

  private

  # A bearer token carrying the scopes sign-on mints for these keys.
  def signed_on_as(keys)
    scopes = Lakeraven::EHR::SessionScopePolicy.scope_string(security_keys: keys, options: CHART_OPTION)
    app = Doorkeeper::Application.create!(name: "chart-link", redirect_uri: "https://example.test/callback",
                                          scopes: scopes, confidential: true)
    token = Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: 3600)
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
