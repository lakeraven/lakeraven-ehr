# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "tmpdir"

# Spec for lakeraven-ehr#663 — per-checkout test database names.
# Implementation target: test/dummy/lib/test_database_name.rb
#   Lakeraven::EHR::TestDatabaseName.resolve(checkout_root:, env:)
class LakeravenEhrTestDatabaseNameTest < ActiveSupport::TestCase
  RESOLVER_RB = File.expand_path("../../../dummy/lib/test_database_name.rb", __dir__)
  BASE = "lakeraven_ehr_test"

  setup do
    flunk("expected resolver at #{RESOLVER_RB}") unless File.exist?(RESOLVER_RB)
    require RESOLVER_RB unless defined?(Lakeraven::EHR::TestDatabaseName)
    @saved_env = {}
    %w[TEST_DATABASE TEST_ENV_NUMBER].each do |key|
      @saved_env[key] = ENV.key?(key) ? ENV[key] : :missing
      ENV.delete(key)
    end
  end

  teardown do
    @saved_env&.each do |key, value|
      if value == :missing
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  test "resolve is defined on Lakeraven::EHR::TestDatabaseName" do
    assert_respond_to Lakeraven::EHR::TestDatabaseName, :resolve
  end

  test "primary checkout with .git directory uses base test database name" do
    Dir.mktmpdir("lr-primary-") do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))

      assert_equal BASE, resolve(checkout_root: root, env: {})
    end
  end

  test "checkout with no .git uses base test database name" do
    Dir.mktmpdir("lr-no-git-") do |root|
      assert_equal BASE, resolve(checkout_root: root, env: {})
    end
  end

  test "linked worktree uses base name plus eight hex digits from realpath digest" do
    Dir.mktmpdir("lr-worktree-") do |root|
      File.write(File.join(root, ".git"), "gitdir: /tmp/example.git/worktrees/demo\n")

      suffix = worktree_suffix(root)
      assert_equal "#{BASE}_#{suffix}", resolve(checkout_root: root, env: {})
    end
  end

  test "two different worktree roots get different database names" do
    names = Dir.mktmpdir("lr-wt-pair-") do |parent|
      roots = 2.times.map do |i|
        path = File.join(parent, "wt#{i}")
        FileUtils.mkdir_p(path)
        File.write(File.join(path, ".git"), "gitdir: /tmp/example.git/worktrees/wt#{i}\n")
        path
      end

      roots.map { |root| resolve(checkout_root: root, env: {}) }
    end

    assert_equal 2, names.uniq.size
    names.each { |name| assert_valid_identifier(name) }
  end

  test "same checkout root and env yields the same name on repeated calls" do
    Dir.mktmpdir("lr-stable-") do |root|
      File.write(File.join(root, ".git"), "gitdir: /tmp/example.git/worktrees/stable\n")
      env = { "TEST_ENV_NUMBER" => "3" }

      first = resolve(checkout_root: root, env: env)
      second = resolve(checkout_root: root, env: env)

      assert_equal first, second
    end
  end

  test "symlinked path to a worktree resolves to the same name as the real path" do
    Dir.mktmpdir("lr-symlink-") do |parent|
      root = File.join(parent, "worktree")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, ".git"), "gitdir: /tmp/example.git/worktrees/link\n")

      link = File.join(parent, "link")
      File.symlink(root, link)

      assert_equal resolve(checkout_root: root, env: {}),
                   resolve(checkout_root: link, env: {})
    end
  end

  test "non-blank TEST_DATABASE is used exactly when valid" do
    Dir.mktmpdir("lr-env-db-") do |root|
      assert_equal "custom_suite_db",
                   resolve(checkout_root: root, env: { "TEST_DATABASE" => "custom_suite_db" })
    end
  end

  test "invalid TEST_DATABASE raises ArgumentError naming TEST_DATABASE" do
    Dir.mktmpdir("lr-bad-db-") do |root|
      assert_raises(ArgumentError) { resolve(checkout_root: root, env: { "TEST_DATABASE" => "bad-name" }) }
      assert_raises(ArgumentError) { resolve(checkout_root: root, env: { "TEST_DATABASE" => "9starts_with_digit" }) }

      valid_max = "a" * 63
      assert_equal valid_max, resolve(checkout_root: root, env: { "TEST_DATABASE" => valid_max })

      too_long = "a" * 64
      error = assert_raises(ArgumentError) { resolve(checkout_root: root, env: { "TEST_DATABASE" => too_long }) }
      assert_includes error.message, "TEST_DATABASE"
    end
  end

  test "blank TEST_DATABASE falls through to checkout-based naming" do
    Dir.mktmpdir("lr-blank-db-") do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))

      assert_equal BASE, resolve(checkout_root: root, env: { "TEST_DATABASE" => "   " })
    end
  end

  test "TEST_ENV_NUMBER appends underscore and digits to the resolved base name" do
    Dir.mktmpdir("lr-env-num-") do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))

      assert_equal "#{BASE}_7", resolve(checkout_root: root, env: { "TEST_ENV_NUMBER" => "7" })
    end
  end

  test "invalid TEST_ENV_NUMBER raises ArgumentError naming TEST_ENV_NUMBER" do
    Dir.mktmpdir("lr-bad-num-") do |root|
      error = assert_raises(ArgumentError) { resolve(checkout_root: root, env: { "TEST_ENV_NUMBER" => "2a" }) }
      assert_includes error.message, "TEST_ENV_NUMBER"
    end
  end

  test "combined resolved name is at most 63 bytes including TEST_ENV_NUMBER suffix" do
    Dir.mktmpdir("lr-len-bound-") do |root|
      base = "a" * 61
      assert_equal "#{base}_1", resolve(
        checkout_root: root,
        env: { "TEST_DATABASE" => base, "TEST_ENV_NUMBER" => "1" }
      )

      base_too_long = "a" * 62
      error = assert_raises(ArgumentError) do
        resolve(
          checkout_root: root,
          env: { "TEST_DATABASE" => base_too_long, "TEST_ENV_NUMBER" => "1" }
        )
      end
      assert_includes error.message, "TEST_ENV_NUMBER"
    end
  end

  test "resolved name is a PostgreSQL-safe identifier at most 63 bytes" do
    cases = [
      { root_kind: :primary, env: {} },
      { root_kind: :worktree, env: {} },
      { root_kind: :primary, env: { "TEST_ENV_NUMBER" => "99" } },
      { root_kind: :worktree, env: { "TEST_DATABASE" => "suite_alpha" } }
    ]

    cases.each do |case_def|
      Dir.mktmpdir("lr-id-") do |root|
        setup_checkout_root!(root, case_def.fetch(:root_kind))
        name = resolve(checkout_root: root, env: case_def.fetch(:env))
        assert_valid_identifier(name)
        assert_operator name.bytesize, :<=, 63
      end
    end
  end

  private

  def resolve(checkout_root:, env:)
    Lakeraven::EHR::TestDatabaseName.resolve(checkout_root: checkout_root, env: env)
  end

  def worktree_suffix(checkout_root)
    Digest::SHA256.hexdigest(File.realpath(checkout_root))[0, 8]
  end

  def setup_checkout_root!(root, kind)
    case kind
    when :primary
      FileUtils.mkdir_p(File.join(root, ".git"))
    when :worktree
      File.write(File.join(root, ".git"), "gitdir: /tmp/example.git/worktrees/id\n")
    else
      raise ArgumentError, "unknown root_kind #{kind.inspect}"
    end
  end

  def assert_valid_identifier(name)
    assert_match(/\A[a-z][a-z0-9_]*\z/, name, "expected PostgreSQL identifier, got #{name.inspect}")
  end
end
