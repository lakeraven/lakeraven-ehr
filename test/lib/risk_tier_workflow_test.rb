# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "yaml"
require "json"

# The "Risk tier" workflow, tested without GitHub: the Classify step's `run:` block is lifted
# out of the YAML and executed against a stub `gh`, with the real (or a stand-in) classifier.
# What this pins is the fail-closed contract: only a classifier that exits 0 and prints
# phone-safe may produce the phone-safe label. The Apply and Verify steps are executed too,
# against a stub `gh` that keeps the PR's labels in a file, because a label step that quietly
# leaves a stale `risk:phone-safe` behind is the one failure that matters.
class RiskTierWorkflowTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github", "workflows", "risk-tier.yml")

  def workflow
    @workflow ||= YAML.safe_load_file(WORKFLOW, aliases: true)
  end

  def triggers
    workflow.fetch("on", workflow[true]) # YAML 1.1 reads a bare `on` as true
  end

  def steps
    workflow.dig("jobs", "risk-tier", "steps")
  end

  def step(id_or_name)
    steps.find { |s| s["id"] == id_or_name || s["name"] == id_or_name }
  end

  # ---- structure ----------------------------------------------------------------------

  test "it runs on pull_request_target, so the PR cannot edit the workflow that labels it" do
    assert triggers.key?("pull_request_target"), "must be pull_request_target"
    refute triggers.key?("pull_request"), "plain pull_request would run the PR's own copy of this file"
  end

  test "it checks out the base commit and never the PR head" do
    checkouts = steps.select { |s| s["uses"].to_s.start_with?("actions/checkout") }
    assert_equal 1, checkouts.size
    assert_equal "${{ github.event.pull_request.base.sha }}", checkouts.first.dig("with", "ref")
  end

  test "no step refers to the PR head or interpolates PR-controlled text into a shell command" do
    text = File.read(WORKFLOW)
    # the explanatory header may name these; only the executable parts are checked
    code = steps.map { |s| [ s["run"], s.dig("with", "ref"), s["env"]&.values ].flatten.compact.join("\n") }.join("\n")
    assert text.include?("pull_request_target")
    [ "pull_request.head", "head_ref", "head.sha", "head.ref", "pull_request.title", "pull_request.body" ].each do |bad|
      refute_includes code, bad, "executable workflow content must not reference #{bad}"
    end
    steps.each do |s|
      assert_no_match(/\$\{\{\s*github\.event\.(pull_request|issue)\.(title|body|head)/, s["run"].to_s)
    end
  end

  test "the label steps do not swallow failures" do
    %w[Apply\ the\ label Verify\ the\ label].each do |name|
      refute step(name).key?("continue-on-error"), "#{name} must be able to fail visibly"
      refute step(name).key?("if"), "#{name} must not be skipped for fork PRs"
    end
  end

  test "the opposite label is removed before the new one is added" do
    run = step("Apply the label")["run"]
    assert_operator run.index("--remove-label"), :<, run.index("--add-label")
  end

  test "overlapping runs on one PR cancel each other, so a stale run cannot relabel a newer push" do
    group = workflow["concurrency"] || workflow.dig("jobs", "risk-tier", "concurrency")
    assert group.is_a?(Hash), "a concurrency block is required"
    assert_equal true, group["cancel-in-progress"]
    assert_includes group["group"].to_s, "github.event.pull_request.number", "the group must be per pull request"
    refute_includes group["group"].to_s, "github.ref", "a ref-keyed group would serialise unrelated PRs"
  end

  test "the Apply and Verify steps still run in order, after Classify" do
    names = steps.map { |s| s["name"] }
    assert_equal [ "Classify", "Apply the label", "Verify the label" ], names.compact.last(3)
  end

  # ---- the Classify step, executed ------------------------------------------------------

  def run_classify(files:, classifier: :real, gh_fails: false, changed: nil)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.mkdir_p(File.join(dir, ".github"))
      FileUtils.mkdir_p(File.join(dir, "stubs"))
      case classifier
      when :real
        FileUtils.cp(File.join(ROOT, "bin", "risk-tier"), File.join(dir, "bin", "risk-tier"))
        FileUtils.cp(File.join(ROOT, ".github", "risk-tiers.txt"), File.join(dir, ".github", "risk-tiers.txt"))
      when :missing
        nil
      else
        first, code = classifier
        File.write(File.join(dir, "bin", "risk-tier"), "#!/bin/sh\ncat >/dev/null\necho #{first}\nexit #{code}\n")
      end
      FileUtils.chmod(0o755, Dir.glob(File.join(dir, "bin", "*")))

      pages = File.join(dir, "stubs", "pages.json")
      File.write(pages, JSON.generate(files))
      File.write(File.join(dir, "stubs", "gh"), <<~SH)
        #!/bin/sh
        #{gh_fails ? 'echo "gh: boom" >&2; exit 1' : "cat #{pages}"}
      SH
      FileUtils.chmod(0o755, File.join(dir, "stubs", "gh"))
      File.write(File.join(dir, "step.sh"), step("classify")["run"])

      summary = File.join(dir, "summary.md")
      output = File.join(dir, "output.txt")
      FileUtils.touch([ summary, output ])
      env = { "PATH" => "#{File.join(dir, 'stubs')}:#{ENV['PATH']}", "GH_TOKEN" => "x", "REPO" => "o/r", "PR" => "1",
              "CHANGED" => (changed || files.size).to_s, "GITHUB_STEP_SUMMARY" => summary, "GITHUB_OUTPUT" => output }
      _out, err, status = Open3.capture3(env, "bash", "step.sh", chdir: dir)
      assert status.success?, "the Classify step itself must not fail: #{err}"
      [ File.read(output)[/tier=(\S+)/, 1], File.read(summary) ]
    end
  end

  def file(name, previous: nil)
    { "filename" => name, "previous_filename" => previous }.compact
  end

  test "a docs-only change is phone-safe" do
    tier, = run_classify(files: [ file("docs/BPRM_PARITY_PLAN.md") ])
    assert_equal "phone-safe", tier
  end

  test "a sensitive file is laptop-only" do
    tier, = run_classify(files: [ file("README.md"), file("app/models/lakeraven/ehr/disclosure.rb") ])
    assert_equal "laptop-only", tier
  end

  test "a rename out of a laptop-only path is laptop-only" do
    tier, = run_classify(files: [ file("app/widget.rb", previous: "app/services/lakeraven/ehr/authentication_service.rb") ])
    assert_equal "laptop-only", tier
  end

  test "a classifier that prints phone-safe but exits 2 is laptop-only" do
    tier, summary = run_classify(files: [ file("README.md") ], classifier: [ "phone-safe", 2 ])
    assert_equal "laptop-only", tier
    assert_includes summary, "classifier exit 2"
  end

  test "a classifier that prints phone-safe but exits 1 is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], classifier: [ "phone-safe", 1 ])
    assert_equal "laptop-only", tier
  end

  test "a classifier that prints nothing sensible is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], classifier: [ "maybe", 0 ])
    assert_equal "laptop-only", tier
  end

  test "a classifier that prints phone-safe and exits 0 is phone-safe (the stub is honest)" do
    tier, = run_classify(files: [ file("README.md") ], classifier: [ "phone-safe", 0 ])
    assert_equal "phone-safe", tier
  end

  test "a missing classifier is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], classifier: :missing)
    assert_equal "laptop-only", tier
  end

  test "a file list that cannot be read is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], gh_fails: true)
    assert_equal "laptop-only", tier
  end

  test "a truncated file list is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], changed: 7)
    assert_equal "laptop-only", tier
  end

  test "a PR at the API cap of 3000 files is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], changed: 3000)
    assert_equal "laptop-only", tier
  end

  test "an ordinary controller nobody listed is laptop-only" do
    tier, = run_classify(files: [ file("README.md"), file("app/controllers/lakeraven/ehr/web_controller.rb") ])
    assert_equal "laptop-only", tier
  end

  # The API hands the Classify step JSON file names. A name with a newline would become two
  # lines in paths.txt, and each half can be a perfectly safe path on its own. The workflow
  # has to see the control character in the JSON, because the classifier only sees lines.
  test "a file name containing a newline is laptop-only, not two safe paths" do
    tier, summary = run_classify(files: [ file("README.md\nREADME.md") ])
    assert_equal "laptop-only", tier
    assert_match(/control character/i, summary)
  end

  test "a file name ending in a carriage return is laptop-only, not the safe path without it" do
    tier, = run_classify(files: [ file("docs/x.md\r") ])
    assert_equal "laptop-only", tier
  end

  test "a previous_filename containing a control character is laptop-only" do
    tier, = run_classify(files: [ file("docs/new.md", previous: "docs/old\u0001.md") ])
    assert_equal "laptop-only", tier
  end

  test "a file name containing a tab is laptop-only" do
    tier, = run_classify(files: [ file("docs/a\tb.md") ])
    assert_equal "laptop-only", tier
  end

  # ---- the Apply and Verify steps, executed -----------------------------------------------

  LABEL_GH = <<~'SH'
    #!/bin/sh
    # Stub gh: labels live in $GH_STATE, one per line; every call is appended to $GH_LOG.
    echo "$*" >> "$GH_LOG"
    prev=""; jqexpr=""
    for a in "$@"; do
      case "$prev" in
        --remove-label)
          if [ -n "$GH_FAIL_REMOVE" ]; then echo "gh: cannot remove" >&2; exit 1; fi
          grep -vxF "$a" "$GH_STATE" > "$GH_STATE.new"; mv "$GH_STATE.new" "$GH_STATE" ;;
        --add-label)
          if [ -n "$GH_FAIL_ADD" ]; then echo "gh: cannot add" >&2; exit 1; fi
          echo "$a" >> "$GH_STATE" ;;
        --jq) jqexpr="$a" ;;
      esac
      prev="$a"
    done
    case "$1 $2" in
      "pr view") jq -n --rawfile s "$GH_STATE" '{labels: ($s | split("\n") | map(select(length > 0)) | map({name: .}))}' | jq -r "$jqexpr" ;;
    esac
    exit 0
  SH

  # Runs the named steps in order against the stub. Returns [exit statuses, final labels, log].
  def run_label_steps(step_names, tier:, labels: [], fail_remove: false, fail_add: false)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "stubs"))
      File.write(File.join(dir, "stubs", "gh"), LABEL_GH)
      FileUtils.chmod(0o755, File.join(dir, "stubs", "gh"))
      state = File.join(dir, "state")
      log = File.join(dir, "log")
      File.write(state, labels.map { |l| "#{l}\n" }.join)
      FileUtils.touch(log)
      env = { "PATH" => "#{File.join(dir, 'stubs')}:#{ENV['PATH']}", "GH_TOKEN" => "x", "REPO" => "o/r", "PR" => "1",
              "TIER" => tier, "GH_STATE" => state, "GH_LOG" => log }
      env["GH_FAIL_REMOVE"] = "1" if fail_remove
      env["GH_FAIL_ADD"] = "1" if fail_add
      statuses = step_names.map do |name|
        File.write(File.join(dir, "step.sh"), step(name)["run"])
        _out, _err, status = Open3.capture3(env, "bash", "step.sh", chdir: dir)
        status.exitstatus
      end
      [ statuses, File.readlines(state, chomp: true).reject(&:empty?).sort, File.readlines(log, chomp: true) ]
    end
  end

  test "Apply then Verify: a phone-safe PR that was laptop-only ends with exactly risk:phone-safe" do
    statuses, labels, log = run_label_steps([ "Apply the label", "Verify the label" ], tier: "phone-safe", labels: [ "risk:laptop-only", "bug" ])
    assert_equal [ 0, 0 ], statuses
    assert_equal [ "bug", "risk:phone-safe" ], labels
    removed = log.index { |l| l.include?("--remove-label risk:laptop-only") }
    added = log.index { |l| l.include?("--add-label risk:phone-safe") }
    assert removed && added, "both calls must happen: #{log.inspect}"
    assert_operator removed, :<, added, "the opposite label must be removed before the new one is added"
  end

  test "Apply then Verify: a laptop-only PR that was phone-safe ends with exactly risk:laptop-only" do
    statuses, labels, = run_label_steps([ "Apply the label", "Verify the label" ], tier: "laptop-only", labels: [ "risk:phone-safe" ])
    assert_equal [ 0, 0 ], statuses
    assert_equal [ "risk:laptop-only" ], labels
  end

  test "Apply then Verify: an unlabeled PR gets the label" do
    statuses, labels, = run_label_steps([ "Apply the label", "Verify the label" ], tier: "laptop-only")
    assert_equal [ 0, 0 ], statuses
    assert_equal [ "risk:laptop-only" ], labels
  end

  test "Apply creates both labels before using them" do
    _statuses, _labels, log = run_label_steps([ "Apply the label" ], tier: "laptop-only")
    assert_equal 2, log.count { |l| l.start_with?("label create") }
    first_edit = log.index { |l| l.start_with?("pr edit") }
    assert log.rindex { |l| l.start_with?("label create") } < first_edit
  end

  test "Apply fails and adds nothing when the stale opposite label cannot be removed" do
    statuses, labels, log = run_label_steps([ "Apply the label", "Verify the label" ], tier: "laptop-only",
                                           labels: [ "risk:phone-safe" ], fail_remove: true)
    assert_operator statuses.first, :>, 0, "Apply must fail visibly"
    assert_equal [ "risk:phone-safe" ], labels, "it must not leave a PR carrying both labels"
    refute(log.any? { |l| l.include?("--add-label") }, "nothing may be added after a failed removal")
    assert_operator statuses.last, :>, 0, "Verify must also fail: the PR is still mislabeled"
  end

  test "Apply fails when the new label cannot be added" do
    statuses, = run_label_steps([ "Apply the label" ], tier: "phone-safe", fail_add: true)
    assert_operator statuses.first, :>, 0
  end

  test "Verify passes on exactly the expected risk label and ignores unrelated labels" do
    statuses, = run_label_steps([ "Verify the label" ], tier: "phone-safe", labels: [ "risk:phone-safe", "bug", "factory-ready" ])
    assert_equal [ 0 ], statuses
  end

  test "Verify fails when both risk labels are present" do
    statuses, = run_label_steps([ "Verify the label" ], tier: "phone-safe", labels: [ "risk:phone-safe", "risk:laptop-only" ])
    assert_operator statuses.first, :>, 0
  end

  test "Verify fails when the wrong risk label is present" do
    statuses, = run_label_steps([ "Verify the label" ], tier: "phone-safe", labels: [ "risk:laptop-only" ])
    assert_operator statuses.first, :>, 0
  end

  test "Verify fails when no risk label is present" do
    statuses, = run_label_steps([ "Verify the label" ], tier: "laptop-only", labels: [ "bug" ])
    assert_operator statuses.first, :>, 0
  end
end
