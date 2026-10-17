# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "yaml"
require "json"

# The "Risk tier" workflow, tested without GitHub: the Classify step's `run:` block is lifted
# out of the YAML and executed against a stub `gh`, with the real (or a stand-in) classifier.
# What this pins is the fail-closed contract: only a classifier that exits 0 and prints
# phone-safe may produce the phone-safe label.
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
end
