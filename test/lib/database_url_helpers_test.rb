# frozen_string_literal: true

require "test_helper"
require_relative "../support/database_url_helpers"

class DatabaseUrlHelpersTest < ActiveSupport::TestCase
  test "redact_database_url masks userinfo without raising" do
    redacted = DatabaseUrlHelpers.redact_database_url("postgres://u:pw@db/app_test")

    assert_not_includes redacted, "u:pw"
    assert_not_includes redacted, "pw"
  end

  test "redact_database_url masks password query param case-insensitively" do
    redacted = DatabaseUrlHelpers.redact_database_url(
      "postgis://db/app_test?sslmode=require&password=s3cret&other=1"
    )

    assert_includes redacted, "sslmode=require"
    assert_includes redacted, "other=1"
    assert_not_includes redacted, "s3cret"
    assert_match(/password=\[REDACTED\]/i, redacted)

    upper = DatabaseUrlHelpers.redact_database_url("postgresql:///app?PASSWORD=hidden")
    assert_match(/PASSWORD=\[REDACTED\]/, upper)
    assert_not_includes upper, "hidden"
  end

  test "filter_database_dbname_query preserves encoding of remaining pairs" do
    query = "database=old&options=-c%20statement_timeout%3D5000&dbname=ignored"
    filtered = DatabaseUrlHelpers.filter_database_dbname_query(query)

    assert_equal "options=-c%20statement_timeout%3D5000", filtered
  end

  test "redact_database_url returns placeholder for unparseable URL" do
    assert_equal "[invalid DATABASE_URL]",
                 DatabaseUrlHelpers.redact_database_url("not a valid uri://\x00")
  end
end
