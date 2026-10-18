# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "uri"

# Regression for lakeraven-ehr#558: the dummy app must register the engine's
# db/migrate path so schema:load populates schema_migrations for every engine
# migration. In-process tests mask this because test/test_helper.rb sets
# ActiveRecord::Migrator.migrations_paths manually — these examples shell out.
class EngineMigrationPathsTest < ActiveSupport::TestCase
  REPO_ROOT = File.expand_path("../..", __dir__)
  DUMMY_ROOT = File.join(REPO_ROOT, "test/dummy")
  ENGINE_MIGRATE_DIR = File.join(REPO_ROOT, "db/migrate")
  DUMMY_SCHEMA_PATH = File.join(DUMMY_ROOT, "db/schema.rb")
  BUMPED_SCHEMA_VERSION = "2099_01_01_000000"

  setup do
    @scratch_db = "lakeraven_ehr_migpath_#{SecureRandom.hex(4)}"
    @database_url = scratch_database_url_for(@scratch_db)
    @tmpdir = Dir.mktmpdir("engine_migration_paths_")
    @bumped_schema_path = File.join(@tmpdir, "schema.rb")
    @migrated_schema_path = File.join(@tmpdir, "migrated_schema.rb")
    @original_dummy_schema_bytes = File.binread(DUMMY_SCHEMA_PATH)
    write_bumped_schema_copy!
    @engine_versions = engine_migration_versions
    refute_empty @engine_versions,
                 "expected at least one engine migration under #{ENGINE_MIGRATE_DIR} " \
                 "(glob: **[0-9]*_*.rb)"
  end

  teardown do
    assert_dummy_schema_unchanged!
  ensure
    drop_scratch_database!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  test "dummy schema:load with bumped schema records every engine migration in schema_migrations" do
    stdout, stderr, status = rails_cli(
      cwd: DUMMY_ROOT,
      argv: %w[db:create db:schema:load],
      extra_env: { "SCHEMA" => @bumped_schema_path }
    )
    assert_predicate status, :success?, cli_failure_message("db:create db:schema:load", stdout, stderr, status)

    versions = schema_migration_versions(cwd: DUMMY_ROOT)
    missing = @engine_versions - versions
    assert_empty missing,
                 "schema_migrations missing engine versions #{missing.inspect} " \
                 "(have #{versions.size} rows, expected #{@engine_versions.size}).\n" \
                 "#{cli_failure_message('schema_migrations check', stdout, stderr, status)}"
  end

  test "dummy db:migrate:status after bumped schema:load reports no NO FILE lines" do
    stdout, stderr, status = rails_cli(
      cwd: DUMMY_ROOT,
      argv: %w[db:create db:schema:load],
      extra_env: { "SCHEMA" => @bumped_schema_path }
    )
    assert_predicate status, :success?, cli_failure_message("db:create db:schema:load", stdout, stderr, status)

    status_out, status_err, status_status = rails_cli(cwd: DUMMY_ROOT, argv: %w[db:migrate:status])
    assert_predicate status_status, :success?,
                     cli_failure_message("db:migrate:status", status_out, status_err, status_status)

    rows = parse_migrate_status_rows(status_out)
    rows_by_version = rows.index_by { |row| row[:version] }
    bumped_version = BUMPED_SCHEMA_VERSION.delete("_")

    illegal_no_file = rows.select do |row|
      row[:name].include?("NO FILE") && row[:version] != bumped_version
    end
    assert_empty illegal_no_file,
                 "db:migrate:status reported missing migration files (other than bumped schema version):\n#{status_out}"

    @engine_versions.each do |version|
      row = rows_by_version[version]
      assert row, "engine migration #{version} missing from db:migrate:status:\n#{status_out}"
      assert_equal "up", row[:status],
                   "expected engine migration #{version} to be up:\n#{status_out}"
      refute_match(/NO FILE/, row[:name],
                   "engine migration #{version} missing migration file on disk:\n#{status_out}")
      assert_equal expected_engine_migration_status_name(version), row[:name],
                   "engine migration #{version} name mismatch:\n#{status_out}"
    end
  end

  test "repo-root db:migrate applies each engine migration exactly once" do
    stdout, stderr, status = rails_cli(
      cwd: REPO_ROOT,
      argv: %w[db:create db:migrate],
      extra_env: { "SCHEMA" => @migrated_schema_path }
    )
    assert_predicate status, :success?, cli_failure_message("db:create db:migrate", stdout, stderr, status)

    versions = schema_migration_versions(cwd: REPO_ROOT)
    @engine_versions.each do |expected|
      count = versions.count(expected)
      assert_equal 1, count,
                   "expected engine migration #{expected} once in schema_migrations, found #{count} " \
                   "(all versions: #{versions.inspect})"
    end
  end

  test "repo-root bumped schema:load records every engine migration without duplicate migration errors" do
    stdout, stderr, status = rails_cli(
      cwd: REPO_ROOT,
      argv: %w[db:create db:schema:load],
      extra_env: { "SCHEMA" => @bumped_schema_path }
    )
    combined = "#{stdout}#{stderr}"
    refute_match(/Duplicate ?migration/i, combined, "duplicate migration error:\n#{combined}")
    assert_predicate status, :success?, cli_failure_message("db:create db:schema:load", stdout, stderr, status)

    versions = schema_migration_versions(cwd: REPO_ROOT)
    missing = @engine_versions - versions
    assert_empty missing,
                 "schema_migrations missing engine versions #{missing.inspect} " \
                 "(have #{versions.size} rows, expected at least #{@engine_versions.size}).\n#{combined}"
  end

  private

  def assert_dummy_schema_unchanged!
    current = File.binread(DUMMY_SCHEMA_PATH)
    assert_equal @original_dummy_schema_bytes, current,
                 "#{DUMMY_SCHEMA_PATH} was modified during the test (tracked file must not be written)"
  end

  def engine_migration_versions
    Dir[File.join(ENGINE_MIGRATE_DIR, "**/[0-9]*_*.rb")]
      .map { |path| File.basename(path)[/\A(\d+)/, 1] }
      .compact
      .sort
  end

  def parse_migrate_status_rows(output)
    output.each_line.filter_map do |line|
      match = line.match(/^\s+(up|down)\s+(\d+)\s+(.+)\s*$/)
      next unless match

      { status: match[1], version: match[2], name: match[3].strip }
    end
  end

  def expected_engine_migration_status_name(version)
    filename = Dir.children(ENGINE_MIGRATE_DIR).find { |entry| entry.start_with?("#{version}_") }
    raise "no migration file for version #{version}" unless filename

    slug = filename.sub(/\.rb\z/, "").split("_", 2).last
    slug.humanize
  end

  def write_bumped_schema_copy!
    schema = File.read(DUMMY_SCHEMA_PATH)
    bumped = schema.sub(
      /define\(version:\s*\d+(?:_\d+)*\)/,
      "define(version: #{BUMPED_SCHEMA_VERSION})"
    )
    File.write(@bumped_schema_path, bumped)
  end

  def rails_env
    ENV.to_h.merge(
      "RAILS_ENV" => "test",
      "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile"),
      "DATABASE_URL" => @database_url
    )
  end

  def rails_cli(cwd:, argv:, extra_env: {})
    flunk "rails_cli refused: @database_url is blank (would fall back to shared test database)" if @database_url.blank?

    env = rails_env.merge(extra_env)
    Open3.capture3(env, "bin/rails", *argv, chdir: cwd)
  end

  def schema_migration_versions(cwd:)
    runner = 'puts ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations ORDER BY version").join("\n")'
    stdout, stderr, status = rails_cli(cwd: cwd, argv: [ "runner", runner ])
    assert_predicate status, :success?, cli_failure_message("runner schema_migrations", stdout, stderr, status)

    stdout.split("\n").map(&:strip).reject(&:empty?)
  end

  def scratch_database_url_for(scratch_db)
    if ENV["DATABASE_URL"].present?
      return scratch_database_url_from_env(scratch_db)
    end

    url = scratch_database_url_from_active_record(scratch_db)
    return url if url

    flunk "could not build scratch DATABASE_URL: ENV['DATABASE_URL'] is unset and " \
          "ActiveRecord::Base.connection_db_config is missing or not PostgreSQL"
  end

  def scratch_database_url_from_env(scratch_db)
    raw = ENV.fetch("DATABASE_URL")
    uri = URI.parse(raw)
    unless uri.scheme&.match?(/\A(?:postgres|postgresql)\z/i)
      flunk "ENV['DATABASE_URL'] must use postgres or postgresql scheme " \
            "(got #{uri.scheme.inspect}; url: #{redact_database_url(raw)})"
    end

    uri.path = "/#{scratch_db}"
    uri.to_s
  rescue URI::InvalidURIError => e
    flunk "could not parse ENV['DATABASE_URL']: #{e.message}"
  end

  def scratch_database_url_from_active_record(scratch_db)
    cfg = ActiveRecord::Base.connection_db_config
    return nil unless cfg

    hash = cfg.configuration_hash
    adapter = hash[:adapter].to_s
    return nil unless adapter.match?(/postgres/)

    username = hash[:username] || hash[:user]
    password = hash[:password]
    host = hash[:host]
    port = hash[:port]

    if host.blank?
      return "postgresql:///#{scratch_db}"
    end

    userinfo = encode_userinfo(username, password)
    auth = userinfo ? "#{userinfo}@" : ""
    port_fragment = port ? ":#{port}" : ""
    "postgresql://#{auth}#{host}#{port_fragment}/#{scratch_db}"
  end

  def encode_userinfo(username, password)
    return nil if username.blank?

    user = URI.encode_uri_component(username)
    return user unless password

    "#{user}:#{URI.encode_uri_component(password)}"
  end

  def redact_database_url(url)
    uri = URI.parse(url)
    uri.userinfo = "[REDACTED]" if uri.userinfo
    uri.to_s
  rescue URI::InvalidURIError
    "[invalid DATABASE_URL]"
  end

  def drop_scratch_database!
    return unless @database_url.present? && @scratch_db.to_s.match?(/\Alakeraven_ehr_migpath_\h+\z/)

    stdout, stderr, status = rails_cli(
      cwd: DUMMY_ROOT,
      argv: %w[db:drop],
      extra_env: { "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1" }
    )
    return if status.success?

    flunk cli_failure_message("db:drop", stdout, stderr, status)
  end

  def cli_failure_message(label, stdout, stderr, status)
    exit_detail = status.respond_to?(:exitstatus) ? status.exitstatus : status
    <<~MSG
      #{label} failed (exit #{exit_detail})
      STDOUT:
      #{stdout}
      STDERR:
      #{stderr}
    MSG
  end
end
