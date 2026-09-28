# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "yaml"

# The gate's own fail-closed promise, tested against the gate.
#
# bin/mutation-gate exists because a green suite is not evidence on a privilege
# surface. That argument only holds if the gate itself cannot report a clean run
# it did not earn — so the one path that decides a mutant WITHOUT running the
# suite (equivalence) gets a test of its own.
class MutationGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GATE = File.join(ROOT, "bin/mutation-gate")

  # A target with a table row to mutate and a verify that always reports green.
  # Every mutant therefore survives, and a gate that ran the suite must exit 1.
  def with_target(behavior_probe:, declared: false)
    Dir.mktmpdir do |dir|
      subject = File.join(dir, "subject.rb")
      File.write(subject, <<~SUBJECT)
        KEY_SCOPES = {
          bh_provider: { read: %w[Patient], write: %w[Patient] },
        }.freeze
      SUBJECT

      verify_log = File.join(dir, "verify.log")
      verify = File.join(dir, "verify.sh")
      File.write(verify, <<~SH)
        #!/bin/sh
        echo run >> #{verify_log}
        echo "1 scenarios (1 passed)"
      SH
      File.chmod(0o755, verify)

      spec = {
        "name" => "Subject",
        "file" => subject,
        "verify" => verify,
        "generated" => {
          "table_row_pattern" => '^\s+(?<key>\w+): \{ read: (?<read>.+), write: (?<write>.+) \},$',
          "operators" => [
            { "id" => "write_becomes_read",
              "replace" => "  {{key}}: { read: {{read}}, write: {{read}} },",
              "why" => "%{key} may write whatever it may read" },
          ],
        },
      }
      spec["behavior_probe"] = behavior_probe if behavior_probe
      if declared
        spec["declared"] = [ {
          "id" => "mints_everything",
          "find" => "write: %w[Patient]",
          "replace" => "write: %w[Patient Observation]",
          "why" => "bh_provider may write Observation it was never granted",
        } ]
      end

      config = File.join(dir, "targets.yml")
      File.write(config, { "targets" => [ spec ] }.to_yaml)

      out, status = Open3.capture2e({ "MUTATION_TARGETS" => config }, GATE, chdir: ROOT)
      yield out, status, verify_log
    end
  end

  # The defect: fingerprint() returns nil when a target declares no probe, and
  # the equivalence test is `b == baseline_behaviour`. nil == nil, so every
  # mutant is classed equivalent, the suite never runs, and the gate exits 0
  # announcing that all killable mutants were killed — the exact false-clean the
  # gate was built to make impossible.
  def test_a_target_without_a_behavior_probe_does_not_pass_without_running_the_suite
    with_target(behavior_probe: nil) do |out, status, verify_log|
      refute_equal 0, status.exitstatus,
        "gate reported success on a target whose every mutant survives:\n#{out}"
      refute_includes out, "All killable mutants killed"

      runs = File.exist?(verify_log) ? File.readlines(verify_log).size : 0
      assert_operator runs, :>, 1,
        "suite ran #{runs} time(s): the mutant was decided without being tested"
    end
  end

  # A probe that exists but does not observe the mutated path is the same
  # false-clean wearing a working gate's clothes. Measured on the real target:
  # before the probe fingerprinted scope_string, both declared scope_string
  # mutants came back "no behaviour change" and the gate still announced that
  # all killable mutants were killed. A DECLARED mutant states its privilege
  # change in `why`; an equivalence verdict on one means the probe is blind,
  # not that the escalation is harmless.
  def test_a_declared_mutant_is_never_filed_equivalent_on_a_probes_word
    probe = "printf constant"       # sees nothing, so every mutant looks equivalent
    with_target(behavior_probe: probe, declared: true) do |out, status, verify_log|
      refute_includes out, "equiv.  mints_everything",
        "a declared privilege change was skipped on a blind probe's word:\n#{out}"
      assert_includes out, "probe blind spot"
      refute_equal 0, status.exitstatus, out

      runs = File.exist?(verify_log) ? File.readlines(verify_log).size : 0
      assert_operator runs, :>, 1, "declared mutant was decided without being tested"
    end
  end

  # Equivalence is still allowed to skip the suite when a probe can actually
  # establish it — otherwise the fix above would just retire the feature.
  def test_a_probe_that_shows_no_behaviour_change_still_skips_the_suite
    probe = "printf constant"       # same fingerprint before and after mutation
    with_target(behavior_probe: probe) do |out, status, _log|
      assert_equal 0, status.exitstatus, out
      assert_includes out, "equivalent mutant(s) skipped"
    end
  end
end
