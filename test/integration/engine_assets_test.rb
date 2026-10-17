# frozen_string_literal: true

require "test_helper"

# The engine layout links one stylesheet: the host's Tailwind build, which
# includes the engine's app/assets/tailwind/lakeraven_ehr/engine.css. With no
# asset pipeline in the bundle, the link resolved to /stylesheets/... and every
# page load logged a RoutingError for it.
class EngineAssetsTest < ActionDispatch::IntegrationTest
  test "the sign-in page's stylesheet is the Tailwind build and is served" do
    get "/lakeraven-ehr/login"
    assert_response :success

    hrefs = css_select("link[rel=stylesheet]").map { |link| link["href"] }
    href = hrefs.find { |h| h.include?("tailwind") }
    assert href, "the sign-in page links no Tailwind stylesheet (links: #{hrefs.inspect})"

    get href
    assert_response :success
    # A utility used only by the engine layout: Tailwind found the engine's views.
    assert_includes response.body, ".max-w-5xl"
    # Engine components: the scoped element defaults and the screening styles.
    assert_includes response.body, ".lr-ehr"
    assert_includes response.body, ".screening-item"
  end
end
