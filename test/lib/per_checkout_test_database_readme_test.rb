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

  test "README explains how to find stale per-worktree database names" do
    body = File.read(README)

    assert body.match?(/psql\s+-l/i) || body.match?(/lakeraven_ehr_test_/i),
           "test/README.md should explain how to list or find stale per-worktree databases " \
           "(e.g. psql -l or names matching lakeraven_ehr_test_)"
  end

  test "README stale database listing also finds red-before-green scratch databases" do
    body = File.read(README)
    listing = body[/List stale per-worktree databases[^\n]*/i].to_s

    assert listing.match?(/grep lakeraven_ehr_(?!test)/i) || listing.match?(/lakeraven_ehr_rbg_/i),
           "test/README.md should list stale databases with a pattern that also matches " \
           "lakeraven_ehr_rbg_* (e.g. grep lakeraven_ehr_), not only lakeraven_ehr_test_"
    assert body.match?(/lakeraven_ehr_rbg_/i),
           "test/README.md should name red-before-green scratch databases (lakeraven_ehr_rbg_*)"
    assert body.match?(/cancel|kill|interrupt|signaled|SIGTERM|SIGINT|stopped/i),
           "test/README.md should say a cancelled or killed red-before-green run can leave " \
           "a stale lakeraven_ehr_rbg_* database"
  end

  test "README documents cleaning up scratch worktrees left by a hard-killed red-before-green run" do
    body = File.read(README)

    assert body.match?(/SIGKILL|kill -9|killed hard|hard.?kill/i),
           "test/README.md should say a hard-killed (e.g. SIGKILL) red-before-green run can leave " \
           "a scratch worktree behind"
    assert body.match?(/git worktree prune/i),
           "test/README.md should document git worktree prune for stale scratch worktrees"
    assert body.match?(/git worktree remove.*--force|worktree remove --force/i),
           "test/README.md should document git worktree remove --force for stale scratch worktrees"
    assert body.match?(/lakeraven_ehr_rbg_|red-before-green/i),
           "worktree cleanup docs should sit alongside red-before-green / scratch database guidance"
  end

  test "README explains that moving a worktree changes its database name" do
    body = File.read(README)

    assert_match(/mov(e|ing).*worktree|worktree.*mov(e|ing)/i, body,
                 "test/README.md should say that moving a worktree changes its database name")
    assert body.match?(/db:create/i) && body.match?(/db:schema:load/i),
           "test/README.md should say a moved worktree needs db:create db:schema:load again"
  end

  test "README explains linked worktrees and submodules use a hashed database name" do
    body = File.read(README)

    assert body.match?(/\.git.*file|file.*\.git/i),
           "test/README.md should mention checkouts whose .git is a file"
    assert body.match?(/submodule|linked worktree|worktree/i),
           "test/README.md should mention linked worktrees or git submodules"
  end
end
