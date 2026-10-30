# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

# Spec for lakeraven-ehr#663 — dummy database.yml must ERB-resolve test.database.
# CI keeps using DATABASE_URL (out of scope for these examples).

class PerCheckoutTestDatabaseYmlTest < ActiveSupport::TestCase
  RESOLVER_RB = File.expand_path("../dummy/lib/test_database_name.rb", __dir__)
  REPO_ROOT = File.expand_path("../..", __dir__)
  DATABASE_YML = File.join(REPO_ROOT, "test/dummy/config/database.yml")
  CHECKOUT_ROOT = REPO_ROOT

  setup do
    @saved_env = {}
    %w[TEST_DATABASE TEST_ENV_NUMBER].each do |key|
      @saved_env[key] = ENV.key?(key) ? ENV[key] : :missing
      ENV.delete(key)
    end
  end

  teardown do
    @saved_env.each do |key, value|
      if value == :missing
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  test "database.yml wires test.database through TestDatabaseName" do
    source = File.read(DATABASE_YML)

    assert_includes source, "TestDatabaseName",
                    "test/dummy/config/database.yml should ERB-resolve test.database via " \
                    "Lakeraven::EHR::TestDatabaseName (see test/dummy/lib/test_database_name.rb)"
  end

  test "rendered database.yml test.database matches resolver for this checkout" do
    ensure_resolver!
    expected = Lakeraven::EHR::TestDatabaseName.resolve(
      checkout_root: CHECKOUT_ROOT,
      env: ENV.to_h
    )
    config = render_database_yml

    assert_equal expected, config.fetch("test").fetch("database")
  end

  test "rendered database.yml honors TEST_DATABASE when set" do
    with_env("TEST_DATABASE" => "explicit_per_suite_name") do
      config = render_database_yml

      assert_equal "explicit_per_suite_name", config.fetch("test").fetch("database")
    end
  end

  test "rendered database.yml keeps development database unchanged" do
    config = render_database_yml

    assert_equal "lakeraven_ehr_dev", config.fetch("development").fetch("database")
  end

  private

  def ensure_resolver!
    flunk("expected resolver at #{RESOLVER_RB}") unless File.exist?(RESOLVER_RB)
    require RESOLVER_RB unless defined?(Lakeraven::EHR::TestDatabaseName)
  end

  def render_database_yml
    YAML.safe_load(ERB.new(File.read(DATABASE_YML)).result, aliases: true)
  end

  def with_env(updates)
    prior = {}
    updates.each_key { |key| prior[key] = ENV.key?(key) ? ENV[key] : :missing }
    updates.each { |key, value| ENV[key] = value }
    yield
  ensure
    prior.each do |key, value|
      if value == :missing
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
