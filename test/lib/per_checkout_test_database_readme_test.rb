# frozen_string_literal: true

require "test_helper"

# Spec for lakeraven-ehr#663 — document per-checkout test DB naming in test/README.md.
class PerCheckoutTestDatabaseReadmeTest < ActiveSupport::TestCase
  README = File.expand_path("../README.md", __dir__)

  test "README documents per-checkout test database naming and cleanup" do
    body = File.read(README)

    assert_match(/TEST_DATABASE/i, body,
                 "test/README.md should document TEST_DATABASE")
    assert_match(/TEST_ENV_NUMBER/i, body,
                 "test/README.md should document TEST_ENV_NUMBER")
    assert_match(/worktree|per-checkout|per checkout/i, body,
                 "test/README.md should explain per-checkout / worktree database names")
    assert body.match?(/dropdb/i) || body.match?(/db:drop/i),
           "test/README.md should explain how to drop a stale per-worktree database " \
           "(e.g. dropdb or bin/rails db:drop)"
  end
end
