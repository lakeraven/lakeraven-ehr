# frozen_string_literal: true

require "test_helper"

# The deployed app mounts the engine under /lakeraven-ehr. A visitor who types the bare host
# or /login lands on the sign-in page instead of a 404.
class HostRedirectsTest < ActionDispatch::IntegrationTest
  test "the bare host goes to the sign-in page" do
    get "/"

    assert_redirected_to "/lakeraven-ehr/login"
    assert_response :found
  end

  test "/login goes to the sign-in page" do
    get "/login"

    assert_redirected_to "/lakeraven-ehr/login"
    assert_response :found
  end

  test "the sign-in page it lands on answers" do
    get "/lakeraven-ehr/login"

    assert_response :success
  end
end
