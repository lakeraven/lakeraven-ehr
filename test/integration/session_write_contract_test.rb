# frozen_string_literal: true

require "test_helper"

# THE LANDING CONTRACT between #486 and #491.
#
# The rule is not "session-derived tokens cannot write". It is:
#
#   A session-derived token may not write where forgery protection is not
#   actually enforced for this request.
#
# `ActionController::API` has no forgery protection, so the FHIR API stays
# read-only for a browser session. `WebController` descends from
# `ActionController::Base` and does, so a browser session may write there —
# subject to everything else it already has to satisfy.
#
# NOTE ON THE TEST ENVIRONMENT: `allow_forgery_protection` is FALSE in test,
# which is how an earlier gate found the login POST's CSRF untested. A test
# asserting "CSRF is on" therefore passes vacuously here unless it turns the
# protection on itself. Every test below that depends on the protection does
# exactly that, and asserts that a request WITHOUT a valid token is refused.
class SessionWriteContractTest < ActionDispatch::IntegrationTest
  setup { Lakeraven::EHR::LoginThrottle.reset! }
  teardown { Lakeraven::EHR::LoginThrottle.reset! }

  # 304 RODRIGUEZ,LINDA holds prc_supervisor, which grants ServiceRequest
  # write — the scope the probe routes check.
  KEYED = { username: "lindarodriguez", password: "test123" }.freeze

  # -- the protection is real, not assumed --------------------------------

  test "the test environment leaves forgery protection off by default" do
    refute ActionController::Base.allow_forgery_protection,
      "if this ever becomes true, the with_csrf helper below is hiding a vacuous pass"
  end

  test "a CSRF-protected route refuses a write with no authenticity token" do
    with_csrf do
      sign_in
      post "/csrf_probe", params: { patient_dfn: "1" }

      assert_response :unprocessable_entity
    end
  end

  test "a CSRF-protected route refuses a write with a bogus authenticity token" do
    with_csrf do
      sign_in
      post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: "not-a-token" }

      assert_response :unprocessable_entity
    end
  end

  # -- writes ARE allowed where the protection is enforced ----------------

  test "a session token may write on a CSRF-protected route" do
    with_csrf do
      sign_in
      before = Lakeraven::EHR::ReconciliationSession.count

      post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: csrf_token }

      assert_response :created
      assert_equal before + 1, Lakeraven::EHR::ReconciliationSession.count,
        "the screening-surface case (#491): a browser session must be able to record"
    end
  end

  test "the write is attributed to the signed-in clinician" do
    with_csrf do
      sign_in
      post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: csrf_token }

      assert_equal "304", Lakeraven::EHR::ReconciliationSession.order(:id).last.clinician_duz
    end
  end

  # -- ...and still have to satisfy everything else -----------------------

  test "a session token without the write scope is still refused on a protected route" do
    with_csrf do
      sign_in("testclerk", "test123") # no security keys, so no scopes at all
      post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: csrf_token }

      assert_response :forbidden
    end
  end

  test "an idle session cannot write on a protected route" do
    with_csrf do
      sign_in
      travel(Lakeraven::EHR::SessionsController::IDLE_TIMEOUT + 1.minute) do
        post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: csrf_token }

        assert_response :unauthorized
      end
    end
  end

  test "a revoked session cannot write on a protected route" do
    with_csrf do
      sign_in
      token = csrf_token # render the form before the token dies
      Doorkeeper::AccessToken.order(:id).last.revoke

      post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: token }
      assert_response :unauthorized
    end
  end

  # -- F1: a FORGED write is refused however the controller weakens CSRF ---

  # The invariant is per-REQUEST verification, not the controller's callback
  # configuration: a forged write (no authenticity token — which a hostile
  # cross-site page cannot obtain) is refused on every controller, whatever
  # strategy it declares.
  #
  #   * :null_session / :reset_session — non-rejecting strategies; the callback
  #     "runs" but lets an unverified request proceed;
  #   * conditional skip — the callback object stays on the class but is inert
  #     for :create, so a membership test still sees it;
  #   * unconditional skip — the callback object is removed entirely.
  #
  # A membership test got only the last one right, which is the one case the
  # old negative control tested — so the suite stayed green over the other
  # three (both review seats, F1).
  %w[
    null_session_probe reset_session_probe conditional_skip_probe csrf_disabled_probe
  ].each do |probe|
    test "a forged write is refused on #{probe}" do
      with_csrf do
        sign_in
        before = Lakeraven::EHR::ReconciliationSession.count

        post "/#{probe}", params: { patient_dfn: "1" } # no authenticity_token

        refute_includes 200..299, response.status,
          "#{probe} let a forged session-derived write through (#{response.status})"
        assert_equal before, Lakeraven::EHR::ReconciliationSession.count
      end
    end
  end

  # The genuine browser request — valid token — still writes on the rejecting
  # (exception) strategy. This is the #491 case; it must not regress to a
  # blanket denial.
  test "a token-bearing write still lands on the rejecting strategy" do
    with_csrf do
      sign_in
      before = Lakeraven::EHR::ReconciliationSession.count

      post "/csrf_probe", params: { patient_dfn: "1", authenticity_token: csrf_token }

      assert_response :created
      assert_equal before + 1, Lakeraven::EHR::ReconciliationSession.count
    end
  end

  # A valid authenticity token IS proof of first-party origin, so a verified
  # write is allowed even on a controller that weakened Rails' own enforcement
  # — the gate is stricter than that controller, never looser. What it can
  # never do is let a *forged* request through, which the loop above pins.
  test "a verified write is allowed even where the callback was skipped" do
    with_csrf do
      sign_in
      before = Lakeraven::EHR::ReconciliationSession.count

      post "/csrf_disabled_probe", params: { patient_dfn: "1", authenticity_token: csrf_token }

      assert_response :created
      assert_equal before + 1, Lakeraven::EHR::ReconciliationSession.count
    end
  end

  # -- the API stays read-only for a browser session ----------------------

  test "a session token cannot drive a state-changing API request" do
    sign_in

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" },
      headers: { "Origin" => "https://evil.example" }

    assert_response :unauthorized
  end

  # The session token authorizes the HTML CHART surface (ChartsController,
  # ActionController::Base) — the browser reaches it with no Authorization
  # header — but NOT the FHIR API (ActionController::API), which is bearer-only.
  # The FHIR fallback was overreach a cross-site Lax GET could ride (#512 F1 /
  # #525); the chart is the only surface that opts into session auth.
  test "a session token authorizes the HTML chart, not the FHIR API" do
    sign_in

    get "/lakeraven-ehr/patients/1" # HTML chart — session fallback allowed
    assert_response :ok
    assert_includes response.body, "Anderson"

    get "/lakeraven-ehr/Patient", params: { _id: "1" } # FHIR API — bearer only
    assert_response :unauthorized
  end

  # A header token is not driven by a cookie, so the contract never touches it.
  test "a header token writes on the API regardless of forgery protection" do
    app = Doorkeeper::Application.create!(
      name: "sys-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: "system/*.read system/*.write", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/*.read system/*.write", expires_in: 3600
    )

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" },
      headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

    assert_response :ok
  end

  private

  def sign_in(username = KEYED[:username], password = KEYED[:password])
    post "/lakeraven-ehr/login", params: { username: username, password: password,
                                           authenticity_token: login_csrf_token }
  end

  # Turn the protection ON for the duration, since the test environment
  # disables it globally and an assertion about CSRF would otherwise be
  # vacuous.
  def with_csrf
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # A valid masked authenticity token for the current session, scraped the way
  # a browser would have it.
  #
  # From the META tag, not the form's hidden input: Rails emits PER-FORM CSRF
  # tokens by default, and a form token is bound to that form's action and
  # method — the login form's token is valid for POST /login and nothing else.
  # The meta token is the session-wide one, which is what a fetch() from the
  # page would send.
  def csrf_token
    get "/lakeraven-ehr/login"
    css_select("meta[name=csrf-token]").first&.[]("content")
  end
  alias login_csrf_token csrf_token
end
