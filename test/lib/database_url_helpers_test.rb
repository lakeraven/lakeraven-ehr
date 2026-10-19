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

  test "redact_database_url masks any query key matching pass case-insensitively" do
    redacted = DatabaseUrlHelpers.redact_database_url("postgresql:///app?passwd=SECRETPW&other=1")

    assert_includes redacted, "other=1"
    assert_match(/passwd=\[REDACTED\]/i, redacted)
    assert_not_includes redacted, "SECRETPW"
  end

  test "redact_database_url omits fragment" do
    redacted = DatabaseUrlHelpers.redact_database_url("postgres://u:pw@db/app#password=SECRETPW")

    assert_not_includes redacted, "#"
    assert_not_includes redacted, "SECRETPW"
    assert_not_includes redacted, "pw"
  end

  test "build_postgresql_url_from_config brackets IPv6 host" do
    url = DatabaseUrlHelpers.build_postgresql_url_from_config(
      { adapter: "postgresql", host: "::1", port: 5432, username: "u", password: "SECRETPW", database: "ignored" },
      "scratch_db"
    )

    assert_includes url, "[::1]"
    assert_not_includes url, "u:SECRETPW@::1"

    resolved = DatabaseUrlHelpers.resolve_connection_url_hash(url)
    assert_equal "scratch_db", resolved[:database]
  end

  test "resolve_connection_url_hash failure message does not echo credentials" do
    bad_url = "postgresql://u:SECRETPW@db_host:5432/x"

    error = assert_raises(DatabaseUrlHelpers::ConnectionUrlResolutionError) do
      DatabaseUrlHelpers.resolve_connection_url_hash(bad_url)
    end

    assert_equal DatabaseUrlHelpers::CONNECTION_URL_RESOLUTION_FAILURE, error.message
    assert_not_includes error.message, "SECRETPW"
  end
end
