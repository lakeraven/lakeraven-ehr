# frozen_string_literal: true

require "test_helper"

# A body Rails can't parse answers 400 and its text never reaches the log (#709).
class MalformedBodyLoggingTest < ActionDispatch::IntegrationTest
  MARKER = "SYNTHETICMARKER7731"

  def logged_during
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  test "a body that parses still reaches the controller" do
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_name: "PROVIDER,TEST" }
    get "/lakeraven-ehr/dashboard"

    assert_response :success
  end

  test "a malformed form body is refused and its text stays out of the log" do
    log = logged_during do
      post "/lakeraven-ehr/login",
        params: "username=#{MARKER}%&a[b]=1&a[b][c]=2",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end

    assert_response :bad_request
    assert_includes log, Lakeraven::EHR::ScrubParseErrors::MESSAGE
    assert_not_includes log, MARKER
  end

  test "a malformed JSON body is refused and its text stays out of the log" do
    log = logged_during do
      post "/lakeraven-ehr/login",
        params: "{\"note\": \"#{MARKER}\"",
        headers: { "CONTENT_TYPE" => "application/json" }
    end

    assert_response :bad_request
    assert_includes log, Lakeraven::EHR::ScrubParseErrors::MESSAGE
    assert_not_includes log, MARKER
  end
end
