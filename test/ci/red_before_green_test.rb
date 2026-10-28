# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"
require "timeout"

# Contract for bin/red-before-green (written before the script; the builder
# does not edit these tests).
#
# The script answers one question for a pull request that changes app code and
# adds or changes minitest files: do those tests FAIL when the app code is put
# back to what the base branch had? A test that passes either way does not test
# the change.
#
#   verdict                exit  meaning
#   EXEMPT                 0     nothing to check (and the reason is printed)
#   RED                    0     at least one test failed without the fix
#   RED-FOR-WRONG-REASON   0     only missing-code errors; warned loudly
#   GREEN-WITHOUT-FIX      1     every test passed without the fix
#   UNDETERMINED           2     could not tell; never treated as a pass
#
# The classification paths run on temp git repos with no Rails. The run paths
# substitute the test command (RBG_TEST_CMD) with a fake that reads the app
# file it is standing in for, so they prove the app code really was restored to
# the base version in the scratch worktree.
class RedBeforeGreenTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/red-before-green", __dir__)
  WORKFLOW = File.expand_path("../../.github/workflows/red-before-green.yml", __dir__)

  # What minitest prints just before its summary. The script reads the summary
  # only from the block that follows this line (gate round 1, finding 1).
  FIN = 'Finished in 0.1s, 1.0 runs/s, 1.0 assertions/s.\n\n'

  # A stand-in for `rails test`: prints a minitest-style summary that depends on
  # what app/greeter.rb says in the directory it runs in, and echoes its args.
  FAKE_RUNNER = <<~RUBY
    puts "ARGS: " + ARGV.join(" ")
    src = File.exist?("app/greeter.rb") ? File.read("app/greeter.rb") : "<missing>"
    puts "SEEN: " + src.strip
    if src.include?("fixed")
      puts "#{FIN}1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
    else
      puts "Failure:\\nGreeterTest#test_it [test/greeter_test.rb:3]:\\nExpected: \\"fixed\\""
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("rbg")
    git "init", "-q", "-b", "main"
    git "config", "user.email", "t@example.test"
    git "config", "user.name", "T"
    write "app/greeter.rb", "# broken\n"
    write "lib/keep.rb", "# keep\n"
    write "test/greeter_test.rb", "# old test\n"
    write "README.md", "docs\n"
    commit "base"
    @base = git("rev-parse", "HEAD").strip
    git "checkout", "-q", "-b", "pr"
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- classification -------------------------------------------------------

  def test_app_and_test_change_is_classified_and_not_exempt
    write "app/greeter.rb", "# fixed\n"
    write "test/greeter_test.rb", "# new test\n"
    commit "fix"

    out, status = run_script("--dry-classify")

    assert_equal 0, status.exitstatus, out
    assert_match(%r{^app: .*app/greeter\.rb}, out)
    assert_match(%r{^tests: .*test/greeter_test\.rb}, out)
    assert_match(/^exempt: no/, out)
  end

  def test_docs_only_change_is_exempt_with_a_reason
    write "README.md", "more docs\n"
    commit "docs"

    out, status = run_script("--dry-classify")

    assert_equal 0, status.exitstatus, out
    assert_match(/^exempt: yes/, out)
    assert_match(/no app-code change/i, out)
  end

  def test_test_only_change_is_exempt_with_a_reason
    write "test/greeter_test.rb", "# more tests\n"
    commit "tests only"

    out, status = run_script

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: EXEMPT/, out)
    assert_match(/no app-code change/i, out)
  end

  def test_app_only_change_is_exempt_because_no_tests_changed
    write "app/greeter.rb", "# fixed\n"
    commit "app only"

    out, status = run_script

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: EXEMPT/, out)
    assert_match(/no changed minitest files/i, out)
  end

  def test_test_dummy_is_not_a_test_path
    write "app/greeter.rb", "# fixed\n"
    write "test/dummy/config/thing_test.rb", "# dummy\n"
    commit "dummy only"

    out, = run_script("--dry-classify")

    assert_match(/^exempt: yes/, out)
    refute_match(%r{test/dummy}, out.lines.grep(/^tests:/).join)
  end

  def test_features_alone_are_not_run_so_the_pr_is_exempt_loudly
    write "app/greeter.rb", "# fixed\n"
    write "features/greeting.feature", "Feature: greeting\n"
    commit "feature only"

    out, status = run_script

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: EXEMPT/, out)
    assert_match(/features/i, out)
  end

  def test_deleted_test_files_are_not_run
    FileUtils.rm(File.join(@dir, "test/greeter_test.rb"))
    write "app/greeter.rb", "# fixed\n"
    commit "delete test"

    out, = run_script("--dry-classify")

    assert_match(/^exempt: yes/, out)
  end

  def test_rbg_exempt_env_skips_the_check_and_says_so
    write "app/greeter.rb", "# fixed\n"
    write "test/greeter_test.rb", "# new test\n"
    commit "fix"

    out, status = run_script(env: { "RBG_EXEMPT" => "1" })

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: EXEMPT/, out)
    assert_match(/RBG_EXEMPT/, out)
  end

  def test_unknown_base_is_undetermined_not_a_pass
    write "app/greeter.rb", "# fixed\n"
    commit "fix"

    out, status = run_script("--base", "no-such-ref")

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  # --- verdicts -------------------------------------------------------------

  def test_red_when_the_tests_fail_against_the_base_app_code
    fixed_pr

    out, status = run_script(env: fake_runner)

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
    # The scratch worktree ran with the BASE app code, not the PR's.
    assert_match(/SEEN: # broken/, out)
    # Only the changed minitest file was handed to the runner.
    assert_match(%r{ARGS: test/greeter_test\.rb$}, out)
  end

  def test_the_pr_checkout_is_left_untouched
    fixed_pr

    run_script(env: fake_runner)

    assert_equal "# fixed\n", File.read(File.join(@dir, "app/greeter.rb"))
    assert_equal "", git("status", "--porcelain")
    assert_equal 1, git("worktree", "list").lines.size, "scratch worktree was not removed"
  end

  def test_an_app_file_added_by_the_pr_is_absent_in_the_scratch_run
    write "app/brand_new.rb", "# fixed\n"
    write "app/greeter.rb", "# fixed\n"
    write "test/greeter_test.rb", "# new test\n"
    commit "adds a file"
    runner = <<~RUBY
      puts(File.exist?("app/brand_new.rb") ? "ADDED-FILE-PRESENT" : "ADDED-FILE-ABSENT")
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(runner))

    assert_equal 0, status.exitstatus, out
    assert_match(/ADDED-FILE-ABSENT/, out)
  end

  def test_a_deleted_app_file_is_restored_in_the_scratch_run
    FileUtils.rm(File.join(@dir, "lib/keep.rb"))
    write "test/greeter_test.rb", "# new test\n"
    commit "deletes a file"
    runner = <<~RUBY
      puts(File.exist?("lib/keep.rb") ? "DELETED-FILE-RESTORED" : "DELETED-FILE-GONE")
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, = run_script(env: fake_runner(runner))

    assert_match(/DELETED-FILE-RESTORED/, out)
  end

  def test_green_without_fix_when_every_test_passes_on_the_base_app_code
    write "app/greeter.rb", "# cosmetic change\n"
    write "test/greeter_test.rb", "# a test that never looks at the change\n"
    commit "tests that do not test"
    passing = <<~RUBY
      puts "#{FIN}5 runs, 9 assertions, 0 failures, 0 errors, 0 skips"
    RUBY

    out, status = run_script(env: fake_runner(passing))

    assert_equal 1, status.exitstatus, out
    assert_match(/^VERDICT: GREEN-WITHOUT-FIX/, out)
  end

  def test_red_for_wrong_reason_when_only_missing_code_errors_occur
    fixed_pr
    errors = <<~RUBY
      puts "Error:\\nGreeterTest#test_it:\\nNameError: uninitialized constant Greeter\\n    app.rb:1"
      puts "Error:\\nGreeterTest#test_two:\\nNoMethodError: undefined method 'hello' for class Greeter"
      puts "#{FIN}2 runs, 0 assertions, 0 failures, 2 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(errors))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED-FOR-WRONG-REASON/, out)
    assert_match(/WARNING/, out)
  end

  def test_one_genuine_failure_among_missing_code_errors_is_red
    fixed_pr
    mixed = <<~RUBY
      puts "Error:\\nGreeterTest#test_it:\\nNameError: uninitialized constant Greeter"
      puts "Failure:\\nGreeterTest#test_two [test/greeter_test.rb:9]:\\nExpected: 1\\n  Actual: 2"
      puts "#{FIN}2 runs, 1 assertions, 1 failures, 1 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(mixed))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
  end

  def test_an_error_that_is_not_missing_code_counts_as_red
    fixed_pr
    other = <<~RUBY
      puts "Error:\\nGreeterTest#test_it:\\nActiveRecord::RecordInvalid: Validation failed"
      puts "#{FIN}1 runs, 0 assertions, 0 failures, 1 errors, 0 skips"
      exit 1
    RUBY

    out, = run_script(env: fake_runner(other))

    assert_match(/^VERDICT: RED$/, out)
  end

  def test_undetermined_when_the_runner_prints_no_summary
    fixed_pr
    crash = <<~RUBY
      puts "boom: could not connect to the database"
      exit 0
    RUBY

    out, status = run_script(env: fake_runner(crash))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  def test_undetermined_when_zero_tests_ran
    fixed_pr
    nothing = <<~RUBY
      puts "#{FIN}0 runs, 0 assertions, 0 failures, 0 errors, 0 skips"
    RUBY

    out, status = run_script(env: fake_runner(nothing))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  # --- gate round 1 (gate/runs/lakeraven-ehr-632/r1/verify.md) --------------
  # Spec amendment: written by the chair after the gate seats' findings, before
  # the fixes. The builder does not edit these.

  # Finding 1: any process in the run can print a line shaped like the summary.
  def test_a_spoofed_summary_line_after_the_real_one_does_not_change_the_verdict
    fixed_pr
    spoofed = <<~RUBY
      puts "Failure:\\nGreeterTest#test_it [test/greeter_test.rb:3]:\\nExpected: 1"
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      puts "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(spoofed))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
  end

  def test_a_spoofed_failure_line_after_a_passing_run_does_not_make_it_red
    fixed_pr
    spoofed = <<~RUBY
      puts "#{FIN}1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
      puts "1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
    RUBY

    out, status = run_script(env: fake_runner(spoofed))

    assert_equal 1, status.exitstatus, out
    assert_match(/^VERDICT: GREEN-WITHOUT-FIX/, out)
  end

  def test_a_spoofed_second_finished_block_is_undetermined_not_a_verdict
    fixed_pr
    spoofed = <<~RUBY
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      puts "#{FIN}1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
    RUBY

    out, status = run_script(env: fake_runner(spoofed))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  def test_a_summary_that_does_not_follow_a_finished_line_is_not_read
    fixed_pr
    bare = <<~RUBY
      puts "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
    RUBY

    out, status = run_script(env: fake_runner(bare))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  def test_an_indented_or_embedded_summary_line_is_not_read
    fixed_pr
    indented = <<~RUBY
      puts "#{FIN}  1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
    RUBY
    embedded = <<~RUBY
      puts "#{FIN}ok: 1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
    RUBY

    [ indented, embedded ].each do |body|
      out, status = run_script(env: fake_runner(body))

      assert_equal 2, status.exitstatus, out
      assert_match(/^VERDICT: UNDETERMINED/, out)
    end
  end

  def test_every_test_skipped_is_undetermined
    fixed_pr
    skipped = <<~RUBY
      puts "#{FIN}3 runs, 0 assertions, 0 failures, 0 errors, 3 skips"
    RUBY

    out, status = run_script(env: fake_runner(skipped))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  def test_a_nonzero_runner_exit_with_no_failures_or_errors_is_undetermined
    fixed_pr
    odd = <<~RUBY
      puts "#{FIN}2 runs, 2 assertions, 0 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(odd))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  # Finding 4: errors are counted but none can be read, so "wrong reason" is a guess.
  def test_errors_with_no_readable_exception_lines_are_undetermined
    fixed_pr
    unreadable = <<~RUBY
      puts "    /gems/minitest.rb:1:in 'run'"
      puts "#{FIN}2 runs, 0 assertions, 0 failures, 2 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(unreadable))

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
    refute_match(/RED-FOR-WRONG-REASON/, out)
  end

  # Finding 3: a dependency or build-file change cannot be put back to the base
  # by restoring app paths, so the check cannot say anything about it.
  %w[Gemfile Gemfile.lock lakeraven-ehr.gemspec Rakefile].each do |dep|
    define_method("test_a_change_to_#{dep.tr('.-', '__')}_with_a_test_change_is_undetermined") do
      write dep, "# changed\n"
      write "test/greeter_test.rb", "# new test\n"
      commit "dependency change with a test"

      out, status = run_script(env: fake_runner)

      assert_equal 2, status.exitstatus, out
      assert_match(/^VERDICT: UNDETERMINED/, out)
      assert_match(/#{Regexp.escape(dep)}/, out)
    end
  end

  def test_a_dependency_change_alongside_an_app_change_is_still_undetermined
    write "Gemfile", "# changed\n"
    fixed_pr

    out, status = run_script(env: fake_runner)

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  def test_a_dependency_change_with_no_test_change_stays_exempt
    write "Gemfile", "# changed\n"
    commit "bump"

    out, status = run_script

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: EXEMPT/, out)
  end

  # Finding 2: the PR's own test harness is what runs the base app code.
  [ "test/test_helper.rb", "test/support/helper.rb", "test/dummy/config/initializers/x.rb" ].each do |harness|
    define_method("test_a_change_to_#{harness.tr('/.', '__')}_prints_a_harness_warning_but_still_gives_a_verdict") do
      write harness, "# changed\n"
      fixed_pr

      out, status = run_script(env: fake_runner)

      assert_equal 0, status.exitstatus, out
      assert_match(/^VERDICT: RED$/, out)
      assert_match(/HARNESS-CHANGED/, out)
      assert_match(/#{Regexp.escape(harness)}/, out)
    end
  end

  def test_no_harness_warning_when_the_harness_is_untouched
    fixed_pr

    out, = run_script(env: fake_runner)

    refute_match(/HARNESS-CHANGED/, out)
  end

  # Finding 7: RED-FOR-WRONG-REASON and HARNESS-CHANGED exit 0 on an advisory job,
  # so CI needs them as annotations, not only in the log.
  def test_warnings_are_annotations_when_asked_and_plain_text_otherwise
    write "test/test_helper.rb", "# changed\n"
    fixed_pr
    errors = <<~RUBY
      puts "Error:\\nGreeterTest#test_it:\\nNameError: uninitialized constant Greeter"
      puts "#{FIN}1 runs, 0 assertions, 0 failures, 1 errors, 0 skips"
      exit 1
    RUBY

    annotated, = run_script(env: fake_runner(errors).merge("RBG_ANNOTATE" => "1"))
    plain, = run_script(env: fake_runner(errors))

    assert_match(/^::warning[^\n]*RED-FOR-WRONG-REASON/, annotated)
    assert_match(/^::warning[^\n]*HARNESS-CHANGED/, annotated)
    refute_match(/^::warning/, plain)
  end

  # Finding 5: the check cannot police a PR that edits the script it runs.
  def test_the_script_and_workflow_state_that_a_pr_can_edit_the_check
    script_head = File.read(SCRIPT).lines.first(60).join
    workflow = File.read(WORKFLOW)

    assert_match(/PR's own copy of this script/, script_head)
    assert_match(/cannot police a PR that edits/, script_head)
    assert_match(/PR's own copy of the script/, workflow)
    assert_match(/cannot police a PR that edits/, workflow)
  end

  def test_the_workflow_stays_on_pull_request_because_it_runs_the_prs_tests
    triggers = File.read(WORKFLOW)[/^on:.*?^jobs:/m]

    assert_match(/^\s+pull_request:/, triggers)
    refute_match(/pull_request_target/, triggers)
    assert_match(/RBG_ANNOTATE/, File.read(WORKFLOW))
  end

  # --- gate round 2 (gate/runs/lakeraven-ehr-632/r2/) -----------------------
  # Spec amendment: written after the round-2 seats' findings, before the fixes.
  # The builder does not edit these.

  # GLM F2: db:schema:load runs on the PR's schema before the base run, so a PR that
  # changes the schema or a migration is tested against a database the base code never had.
  [ "db/schema.rb", "db/migrate/20260101000000_add_thing.rb" ].each do |db_file|
    define_method("test_a_change_to_#{db_file.tr('/.', '__')}_prints_a_db_warning_but_still_gives_a_verdict") do
      write db_file, "# changed\n"
      fixed_pr

      out, status = run_script(env: fake_runner)

      assert_equal 0, status.exitstatus, out
      assert_match(/^VERDICT: RED$/, out)
      assert_match(/DB-CHANGED/, out)
      assert_match(/#{Regexp.escape(db_file)}/, out)
    end
  end

  def test_no_db_warning_when_the_schema_and_migrations_are_untouched
    fixed_pr

    out, = run_script(env: fake_runner)

    refute_match(/DB-CHANGED/, out)
  end

  def test_the_db_warning_is_an_annotation_when_asked
    write "db/schema.rb", "# changed\n"
    fixed_pr

    annotated, = run_script(env: fake_runner.merge("RBG_ANNOTATE" => "1"))
    plain, = run_script(env: fake_runner)

    assert_match(/^::warning[^\n]*DB-CHANGED/, annotated)
    refute_match(/^::warning/, plain)
  end

  # Composer #6: bin/ scripts are neither app code nor a dependency file, so a bin/ change
  # plus tests used to be EXEMPT ("no app-code change") although it can change behavior.
  def test_a_bin_change_with_a_test_change_is_undetermined
    write "bin/setup", "# changed\n"
    write "test/greeter_test.rb", "# new test\n"
    commit "bin change with a test"

    out, status = run_script(env: fake_runner)

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
    assert_match(%r{bin/setup}, out)
  end

  def test_a_bin_change_alongside_an_app_change_is_still_undetermined
    write "bin/setup", "# changed\n"
    fixed_pr

    out, status = run_script(env: fake_runner)

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
  end

  def test_a_bin_change_with_no_test_change_stays_exempt
    write "bin/setup", "# changed\n"
    commit "script tweak"

    out, status = run_script

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: EXEMPT/, out)
  end

  # Composer #5: a runner that writes CRLF line endings must not turn a complete
  # minitest run into UNDETERMINED.
  def test_a_crlf_summary_is_still_read
    fixed_pr
    crlf = <<~RUBY
      print "Failure:\\r\\nGreeterTest#test_it [test/greeter_test.rb:3]:\\r\\nExpected: 1\\r\\n"
      print "Finished in 0.1s, 1.0 runs/s, 1.0 assertions/s.\\r\\n\\r\\n1 runs, 1 assertions, 1 failures, 0 errors, 0 skips\\r\\n"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(crlf))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
  end

  # GLM F4: the annotation line reads $1 after the details are shifted away; under
  # `set -u` a verdict with no detail line must still print its verdict and exit with its code.
  def test_a_verdict_with_no_detail_line_survives_set_u_when_annotating
    function = File.read(SCRIPT)[/^verdict\(\) \{.*?^\}$/m]
    refute_nil function, "verdict() not found in #{SCRIPT}"
    program = "set -uo pipefail\nHARNESS_FILES=''\nDB_FILES=''\n#{function}\nverdict UNDETERMINED 2\n"

    out, status = Open3.capture2e({ "RBG_ANNOTATE" => "1" }, "bash", "-c", program)

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
    refute_match(/unbound variable/, out)
  end

  # GLM F1 / Composer #7: one forged "Finished in" block printed by any process in the run is
  # still trusted. The script cannot close that, so it has to say so where a reader will see it.
  def test_the_script_and_workflow_name_the_single_forged_block_floor
    script_header = File.read(SCRIPT)[/\A.*?^set -u/m]
    workflow_header = File.read(WORKFLOW)[/\A.*?^on:/m]

    [ script_header, workflow_header ].each do |header|
      assert_match(/single forged "Finished in" block/, header)
      assert_match(/known floor/, header)
    end
  end

  # --- gate round 3 (gate/runs/lakeraven-ehr-632/r3/) -----------------------
  # Spec amendment: tests only; each pins a mutation the round-2 suite let survive.

  # GLM r3 F1: db/structure.sql (schema_format :sql) is in the DB glob but was never exercised.
  def test_a_change_to_db_structure_sql_prints_a_db_warning_but_still_gives_a_verdict
    write "db/structure.sql", "-- changed\n"
    fixed_pr

    out, status = run_script(env: fake_runner)

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
    assert_match(%r{DB-CHANGED.*db/structure\.sql}, out)
  end

  # GLM r3 F3: the warning is only useful because it says why. Pin the explanation.
  def test_the_db_warning_explains_that_the_database_is_the_prs_and_is_not_reverted
    write "db/schema.rb", "# changed\n"
    fixed_pr

    out, = run_script(env: fake_runner)
    warning = out[/^.*DB-CHANGED.*$/].to_s

    assert_match(/loaded from the PR's schema before the base run/, warning)
    assert_match(/not reverted/, warning)
    assert_match(/schema it never had/, warning)
  end

  # GLM r3 F2: the error-reading step must see CRLF output too. A CRLF run with only
  # missing-code errors is RED-FOR-WRONG-REASON; with a real failure among them, RED.
  def test_crlf_output_with_only_missing_code_errors_is_red_for_wrong_reason
    fixed_pr
    crlf = <<~RUBY
      print "Error:\\r\\nGreeterTest#test_it:\\r\\nNameError: uninitialized constant Greeter\\r\\n    app.rb:1\\r\\n"
      print "Finished in 0.1s, 1.0 runs/s, 1.0 assertions/s.\\r\\n\\r\\n1 runs, 0 assertions, 0 failures, 1 errors, 0 skips\\r\\n"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(crlf))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED-FOR-WRONG-REASON/, out)
  end

  def test_crlf_output_with_a_non_missing_code_error_is_red
    fixed_pr
    crlf = <<~RUBY
      print "Error:\\r\\nGreeterTest#test_it:\\r\\nActiveRecord::RecordInvalid: Validation failed\\r\\n"
      print "Finished in 0.1s, 1.0 runs/s, 1.0 assertions/s.\\r\\n\\r\\n1 runs, 0 assertions, 0 failures, 1 errors, 0 skips\\r\\n"
      exit 1
    RUBY

    out, status = run_script(env: fake_runner(crlf))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
  end

  # --- Copilot round (PR #632 thread on the workflow's bundler-cache) --------
  # Spec amendment: written after the finding, before the fix. The builder does not
  # edit these.
  #
  # ruby/setup-ruby with bundler-cache installs gems under the checkout's vendor/bundle
  # and records that path with `bundle config --local`, i.e. in the checkout's own
  # .bundle/config. That file is gitignored, so the scratch worktree the script runs the
  # tests in does not have it, and `bundle exec rails test` there cannot find the gems
  # (verdict UNDETERMINED, no tests run). BUNDLE_PATH in the environment is read by every
  # bundler process, whatever its directory, so the step must pass it, and it must be
  # absolute: a relative path would resolve against the scratch worktree.

  def script_step
    steps = YAML.load_file(WORKFLOW).fetch("jobs").fetch("red-before-green").fetch("steps")
    steps.find { |step| step["run"].to_s.include?("bin/red-before-green") } or flunk("no step runs bin/red-before-green")
  end

  def test_the_workflow_installs_gems_with_the_setup_ruby_bundler_cache
    setup = YAML.load_file(WORKFLOW).fetch("jobs").fetch("red-before-green").fetch("steps")
      .find { |step| step["uses"].to_s.start_with?("ruby/setup-ruby") }

    assert setup, "the workflow must install ruby with ruby/setup-ruby"
    assert_equal true, setup.fetch("with").fetch("bundler-cache")
  end

  def test_the_script_step_hands_the_scratch_worktree_an_absolute_bundle_path
    bundle_path = script_step.fetch("env", {})["BUNDLE_PATH"].to_s

    refute_empty bundle_path, "the step that runs the script must set BUNDLE_PATH for the scratch worktree"
    assert_match(%r{\A(/|\$\{\{ github\.workspace \}\}/)}, bundle_path, "BUNDLE_PATH must be absolute")
  end

  def test_the_bundle_path_is_where_setup_ruby_installed_the_gems
    bundle_path = script_step.fetch("env", {})["BUNDLE_PATH"].to_s

    assert_equal "${{ github.workspace }}/vendor/bundle", bundle_path,
      "setup-ruby's bundler-cache installs into the checkout's vendor/bundle, so BUNDLE_PATH must name exactly that"
  end

  # Not red before the fix (the script already runs the tests with its own environment):
  # it pins that the script must keep passing BUNDLE_PATH through to the test command.
  def test_a_bundle_path_in_the_environment_reaches_the_test_command_in_the_scratch_worktree
    write "app/greeter.rb", "# fixed\n"
    write "test/greeter_test.rb", "# new test\n"
    commit "pr"
    runner = "puts \"BUNDLE_PATH=\#{ENV['BUNDLE_PATH']}\"\nputs \"PWD=\#{Dir.pwd}\"\n" \
             "puts \"#{FIN}1 runs, 1 assertions, 0 failures, 0 errors, 0 skips\""
    # The fake runner is a plain ruby process: keep the outer bundle exec's setup out of it.
    env = fake_runner(runner).merge("BUNDLE_PATH" => "/abs/vendor/bundle", "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil)
    out, = run_script(env: env)

    assert_match(%r{^BUNDLE_PATH=/abs/vendor/bundle$}, out)
    refute_includes out[/^PWD=.*$/].to_s, @dir, "the tests must run in the scratch worktree, not the PR checkout"
  end

  # --- lakeraven-ehr#663 panel round 1 ----------------------------------------
  # Spec amendment: scratch worktree runs need a throwaway test DB when DATABASE_URL
  # is unset (the default per-worktree name does not exist there).

  def test_without_database_url_setup_teardown_and_test_share_test_database_in_scratch_worktree
    fixed_pr
    env = fake_runner(<<~RUBY).merge(fake_db_commands)
      puts "RUNNER TEST_DATABASE=\#{ENV['TEST_DATABASE']}"
      puts "Failure:\\nGreeterTest#test_it [test/greeter_test.rb:3]:\\nExpected: 1"
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: env.merge("DATABASE_URL" => ""))

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
    setup = out[/^DB_SETUP .*$/m]
    runner = out[/^RUNNER TEST_DATABASE=.*$/m]
    teardown = out[/^DB_TEARDOWN .*$/m]
    refute_nil setup
    refute_nil runner
    refute_nil teardown, "teardown must run even after a RED verdict"
    db = setup[/TEST_DATABASE=(\S+)/, 1]
    assert_match(/\Alakeraven_ehr_rbg_[a-z0-9_]+\z/, db)
    assert_equal db, runner[/TEST_DATABASE=(\S+)/, 1]
    assert_equal db, teardown[/TEST_DATABASE=(\S+)/, 1]
    assert_match(/DB_SETUP pwd=wt /, setup)
    assert_match(/DB_TEARDOWN pwd=wt /, teardown)
  end

  def test_without_database_url_two_invocations_get_different_test_database_names
    fixed_pr
    env = fake_runner(<<~RUBY).merge(fake_db_commands).merge("DATABASE_URL" => "")
      puts "RUNNER TEST_DATABASE=\#{ENV['TEST_DATABASE']}"
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out1, = run_script(env: env)
    out2, = run_script(env: env)
    name1 = out1[/^RUNNER TEST_DATABASE=(\S+)/m, 1]
    name2 = out2[/^RUNNER TEST_DATABASE=(\S+)/m, 1]

    refute_equal name1, name2
  end

  def test_with_database_url_set_no_test_database_setup_or_teardown
    fixed_pr
    env = fake_runner(<<~RUBY).merge(fake_db_commands).merge("DATABASE_URL" => "postgres://ci.example/test")
      puts "RUNNER TEST_DATABASE=\#{ENV['TEST_DATABASE'].inspect}"
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: env)

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
    assert_match(/^RUNNER TEST_DATABASE=nil$/, out[/^RUNNER TEST_DATABASE=nil$/m])
    refute_match(/^DB_SETUP /m, out)
    refute_match(/^DB_TEARDOWN /m, out)
  end

  def test_database_setup_failure_is_undetermined_not_red_or_green
    fixed_pr
    env = fake_runner(<<~RUBY).merge(fake_db_commands(setup_exit: 1)).merge("DATABASE_URL" => "")
      puts "#{FIN}1 runs, 1 assertions, 0 failures, 0 errors, 0 skips"
    RUBY

    out, status = run_script(env: env)

    assert_equal 2, status.exitstatus, out
    assert_match(/^VERDICT: UNDETERMINED/, out)
    assert_match(/database setup/i, out)
    refute_match(/^VERDICT: RED$/, out)
    refute_match(/^VERDICT: GREEN-WITHOUT-FIX/, out)
  end

  # --- lakeraven-ehr#663 panel round 2 ----------------------------------------
  # Spec amendment: trap must run teardown only after the test process exits on
  # SIGTERM/SIGINT, not only on normal EXIT.

  def test_sigterm_stops_the_test_process_before_teardown_runs
    assert_signal_cleanup("TERM")
  end

  def test_sigint_stops_the_test_process_before_teardown_runs
    assert_signal_cleanup("INT")
  end

  # --- lakeraven-ehr#663 panel round 3 ----------------------------------------
  # Spec amendment: Opus / GLM findings on TEST_ENV_NUMBER, double TERM, cleanup
  # under signal. The builder does not edit these.

  def test_without_database_url_db_commands_unset_test_env_number_and_share_printed_test_database
    fixed_pr
    env = fake_runner(<<~RUBY).merge(fake_db_commands).merge("DATABASE_URL" => "", "TEST_ENV_NUMBER" => "2")
      puts "RUNNER TEST_DATABASE=\#{ENV['TEST_DATABASE']} TEST_ENV_NUMBER=\#{ENV['TEST_ENV_NUMBER'].inspect}"
      puts "Failure:\\nGreeterTest#test_it [test/greeter_test.rb:3]:\\nExpected: 1"
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script(env: env)

    assert_equal 0, status.exitstatus, out
    assert_match(/^VERDICT: RED$/, out)
    printed_db = out[/^test database: (\S+)/m, 1]
    refute_nil printed_db, "script must print the throwaway TEST_DATABASE name\n#{out}"
    setup = out.lines.find { |l| l.start_with?("DB_SETUP ") }
    runner = out.lines.find { |l| l.start_with?("RUNNER TEST_DATABASE=") }
    teardown = out.lines.find { |l| l.start_with?("DB_TEARDOWN pwd=") }
    refute_nil setup
    refute_nil runner
    refute_nil teardown
    assert_match(/TEST_ENV_NUMBER=<unset>/, setup)
    assert_match(/TEST_ENV_NUMBER=nil/, runner)
    assert_match(/TEST_ENV_NUMBER=<unset>/, teardown)
    [ setup, runner, teardown ].each do |line|
      assert_equal printed_db, line[/TEST_DATABASE=(\S+)/, 1],
                   "every step must use the printed TEST_DATABASE exactly\n#{line}"
    end
  end

  def test_second_term_while_test_ignores_term_waits_for_kill_before_teardown
    test_pid = nil
    fixed_pr
    pid_file = File.join(@dir, "rbg-test.pid")
    runner = <<~RUBY
      Signal.trap("TERM", "IGNORE")
      File.write(#{pid_file.inspect}, Process.pid.to_s)
      $stdout.sync = true
      puts "RUNNER STARTED pid=\#{Process.pid}"
      sleep 30
    RUBY
    env = fake_runner(runner).merge(fake_db_commands(test_pid_file: pid_file)).merge("DATABASE_URL" => "")

    out, status, elapsed, test_pid = run_script_async(signal: "TERM", second_signal: "TERM", second_delay: 0.5, env: env)

    assert_operator elapsed, :<, 12,
                    "script should escalate past a TERM-ignoring test and finish cleanup\n#{out}"
    refute_equal 0, status.exitstatus, out
    refute process_listed_in_ps?(test_pid), "test process must not survive double TERM handling\n#{ps_snapshot}\n#{out}"
    refute_match(/^DB_TEARDOWN VIOLATION /m, out)
    refute_match(/child_alive_at_teardown=yes/, out)
    assert_match(/^DB_TEARDOWN .* child_alive_at_teardown=no/m, out)
  ensure
    kill_orphan(test_pid)
  end

  def test_term_during_slow_teardown_still_drops_db_removes_worktree_and_exits_red
    fixed_pr
    worktrees_before = git("worktree", "list")
    env = fake_runner(<<~RUBY).merge(fake_db_commands(teardown_sleep: 2)).merge("DATABASE_URL" => "")
      puts "Failure:\\nGreeterTest#test_it [test/greeter_test.rb:3]:\\nExpected: 1"
      puts "#{FIN}1 runs, 1 assertions, 1 failures, 0 errors, 0 skips"
      exit 1
    RUBY

    out, status = run_script_until_teardown_then_signal(env: env, signal: "TERM")

    refute_nil status
    assert status.exited?, "script must exit normally after cleanup, not only from an uncaught signal\n#{out}"
    assert_equal 0, status.exitstatus, "RED verdict exit code must survive a signal during cleanup\n#{out}"
    assert_match(/^VERDICT: RED$/, out)
    assert_match(/^DB_TEARDOWN_DONE /m, out, "slow teardown must finish despite TERM\n#{out}")
    assert_match(/^DB_TEARDOWN_START /m, out)
    done_at = out.index("DB_TEARDOWN_DONE ")
    start_at = out.index("DB_TEARDOWN_START ")
    refute_nil start_at
    refute_nil done_at
    assert_operator done_at, :>, start_at
    assert_equal worktrees_before, git("worktree", "list"),
                 "scratch worktree must be removed after cleanup"
  end

  private

  def kill_orphan(test_pid)
    return unless test_pid && process_alive?(test_pid)

    begin
      Process.kill("KILL", test_pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  def assert_signal_cleanup(signal)
    test_pid = nil
    fixed_pr
    pid_file = File.join(@dir, "rbg-test.pid")
    runner = <<~RUBY
      File.write(#{pid_file.inspect}, Process.pid.to_s)
      $stdout.sync = true
      puts "RUNNER STARTED pid=\#{Process.pid}"
      sleep 30
    RUBY
    env = fake_runner(runner).merge(fake_db_commands(test_pid_file: pid_file)).merge("DATABASE_URL" => "")

    out, status, elapsed, test_pid = run_script_async(signal: signal, env: env)

    assert_operator elapsed, :<, 8, "script should exit promptly on #{signal}, not wait for the fake test sleep"
    refute_equal 0, status.exitstatus, "script should exit non-zero when interrupted (#{signal})\n#{out}"
    refute process_alive?(test_pid), "fake test process should not be orphaned after #{signal}\n#{out}"
    refute_match(/^DB_TEARDOWN VIOLATION /m, out, "teardown must run only after the test process has ended")
    setup_db = out.lines.find { |l| l.start_with?("DB_SETUP ") }[/TEST_DATABASE=(\S+)/, 1]
    teardown = out.lines.find { |l| l.start_with?("DB_TEARDOWN pwd=") }
    refute_nil teardown, "teardown must run on #{signal}\n#{out}"
    assert_equal setup_db, teardown[/TEST_DATABASE=(\S+)/, 1]
  ensure
    if test_pid && process_alive?(test_pid)
      begin
        Process.kill("KILL", test_pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end

  def run_script_until_teardown_then_signal(env:, signal:)
    reader, writer = IO.pipe
    child = ENV.to_h.merge("RBG_EXEMPT" => "0")
    child.delete("DATABASE_URL") unless env.key?("DATABASE_URL")
    db_env = env.key?("RBG_DB_SETUP_CMD") ? {} : fake_db_commands
    full_env = child.merge(db_env).merge(env)
    script_pid = spawn(full_env, SCRIPT, "--base", @base, chdir: @dir, out: writer, err: writer)
    writer.close
    buf = +""
    reader_thread = Thread.new do
      loop do
        buf << reader.readpartial(4096)
      rescue EOFError
        break
      end
    end
    Timeout.timeout(20) do
      sleep 0.05 until buf.include?("DB_TEARDOWN_START ")
    end
    sleep 0.2
    Process.kill(signal, script_pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    status = nil
    loop do
      waited_pid, st = Process.wait2(script_pid, Process::WNOHANG)
      if waited_pid
        status = st
        break
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", script_pid)
        flunk "script did not finish within 15s after signal during teardown\n#{buf}"
      end
      sleep 0.05
    end
    reader_thread.join(5)
    [ buf, status ]
  end

  def run_script_async(signal:, env: {}, second_signal: nil, second_delay: nil)
    test_pid_path = File.join(@dir, "rbg-test.pid")
    reader, writer = IO.pipe
    child = ENV.to_h.merge("RBG_EXEMPT" => "0")
    child.delete("DATABASE_URL") unless env.key?("DATABASE_URL")
    full_env = child.merge(fake_db_commands(test_pid_file: test_pid_path)).merge(env)
    args = [ "--base", @base ]
    script_pid = spawn(full_env, SCRIPT, *args, chdir: @dir, out: writer, err: writer)
    writer.close
    buf = +""
    reader_thread = Thread.new { buf << reader.read }
    test_pid = nil
    Timeout.timeout(15) do
      sleep 0.05 until File.exist?(test_pid_path)
      test_pid = File.read(test_pid_path).strip.to_i
      break if test_pid.positive?
    end
    flunk("fake test never wrote #{test_pid_path}") unless test_pid&.positive?

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Process.kill(signal, script_pid)
    if second_signal
      sleep second_delay || 0.5
      Process.kill(second_signal, script_pid) if process_alive?(script_pid)
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    status = nil
    loop do
      waited_pid, st = Process.wait2(script_pid, Process::WNOHANG)
      if waited_pid
        status = st
        break
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", script_pid)
        flunk "script did not exit within 10s after #{signal} (must stop the test process and run teardown)"
      end
      sleep 0.05
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    reader_thread.join(5)
    [ buf, status, elapsed, test_pid ]
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def ps_snapshot
    `ps -eo pid,ppid,cmd`
  end

  def process_listed_in_ps?(pid)
    ps_snapshot.lines.any? { |line| line.split.first.to_i == pid }
  end

  def fixed_pr
    write "app/greeter.rb", "# fixed\n"
    write "test/greeter_test.rb", "# new test\n"
    commit "fix with test"
  end

  def fake_runner(body = FAKE_RUNNER)
    # Outside the temp repo so it never shows up as a change.
    path = File.join(Dir.mktmpdir("rbg-runner"), "runner.rb")
    File.write(path, body)
    { "RBG_TEST_CMD" => "ruby #{path}" }
  end

  def fake_db_commands(setup_exit: 0, test_pid_file: nil, teardown_sleep: 0)
    @db_cmd_seq = (@db_cmd_seq || 0) + 1
    dir = File.join(@dir, ".git", "rbg-db-cmd-#{@db_cmd_seq}")
    FileUtils.mkdir_p(dir)
    setup = File.join(dir, "setup.sh")
    teardown = File.join(dir, "teardown.sh")
    teardown_child_check = if test_pid_file
                             <<~SH
                               test_pid=$(cat #{test_pid_file} 2>/dev/null || true)
                               child_alive=no
                               if [ -n "$test_pid" ] && kill -0 "$test_pid" 2>/dev/null; then
                                 child_alive=yes
                                 echo "DB_TEARDOWN VIOLATION test_pid_still_running=$test_pid TEST_DATABASE=${TEST_DATABASE:-}"
                                 exit 1
                               fi
                             SH
    else
                             <<~SH
                               child_alive=no
                             SH
    end
    env_number_field = 'if [ -n "${TEST_ENV_NUMBER+x}" ]; then echo -n "TEST_ENV_NUMBER=${TEST_ENV_NUMBER}"; else echo -n "TEST_ENV_NUMBER=<unset>"; fi'
    File.write(setup, <<~SH)
      #!/usr/bin/env bash
      echo "DB_SETUP pwd=$(basename "$PWD") TEST_DATABASE=${TEST_DATABASE:-} $(#{env_number_field})"
      exit #{setup_exit}
    SH
    File.write(teardown, <<~SH)
      #!/usr/bin/env bash
      #{teardown_child_check}
      echo "DB_TEARDOWN pwd=$(basename "$PWD") TEST_DATABASE=${TEST_DATABASE:-} $(#{env_number_field}) child_alive_at_teardown=$child_alive"
      echo "DB_TEARDOWN_START TEST_DATABASE=${TEST_DATABASE:-}"
      sleep #{teardown_sleep.to_f}
      echo "DB_TEARDOWN_DONE TEST_DATABASE=${TEST_DATABASE:-}"
    SH
    FileUtils.chmod(0o755, setup)
    FileUtils.chmod(0o755, teardown)
    {
      "RBG_DB_SETUP_CMD" => setup,
      "RBG_DB_TEARDOWN_CMD" => teardown
    }
  end

  def run_script(*args, env: {})
    args = [ "--base", @base ] + args unless args.include?("--base")
    child = ENV.to_h.merge("RBG_EXEMPT" => "0")
    child.delete("DATABASE_URL") unless env.key?("DATABASE_URL")
    db_env = env.key?("RBG_DB_SETUP_CMD") ? {} : fake_db_commands
    out, status = Open3.capture2e(child.merge(db_env).merge(env), SCRIPT, *args, chdir: @dir)
    [ out, status ]
  end

  def write(rel, content)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def commit(message)
    git "add", "--all"
    git "commit", "-q", "-m", message
  end

  def git(*args)
    out, status = Open3.capture2e("git", *args, chdir: @dir)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
