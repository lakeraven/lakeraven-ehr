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
    [ "pull_request.head", "head_ref", "head.ref", "head.repo", "pull_request.title", "pull_request.body" ].each do |bad|
      refute_includes code, bad, "executable workflow content must not reference #{bad}"
    end
    # The head commit may be READ as data from the API (`gh api repos/.../pulls/N --jq .head.sha`) to tie the file
    # list to one commit. It must never come from an event expression or reach a checkout or a command line
    # as PR-controlled text: only a jq filter on a `gh api` call may name it.
    code.lines.select { |l| l.include?("head.sha") }.each do |l|
      assert_match(/gh api .*--jq\s+\S*head\.sha/, l, "head.sha may appear only as a jq filter on a gh api call: #{l.strip}")
      refute_includes l, "${{", "head.sha must not come from an expression: #{l.strip}"
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

  # A stand-in `jq` that behaves like the real one except for the one call named by `jq_fail`:
  #   :slurp   `jq -s`        merging the API pages          -> exit 5, no output
  #   :count   `jq length`    counting the files             -> exit 5, no output
  #   :check   `jq -e`        the control-character check    -> exit 5, no output
  #   :extract `jq -r`        writing the names to paths.txt -> first line, then exit 5
  #   :existing `jq` with "removed" in its filter: listing the paths that still exist -> exit 5
  #   :modes   `jq -rn` the mode check over the PR head's tree  -> exit 5, no output
  # Each is a jq that dies (out of memory, a bad build, a killed process): the step must not
  # read a dead jq as "nothing wrong".
  JQ_STUB = <<~'SH'
    #!/bin/sh
    case "$JQ_FAIL:$*" in
      existing:*removed*) echo "jq: error: boom" >&2; exit 5 ;;
    esac
    case "$JQ_FAIL:$1" in
      slurp:-s|check:-e) echo "jq: error: boom" >&2; exit 5 ;;
      count:length) echo "jq: error: boom" >&2; exit 5 ;;
      extract:-r) "$REAL_JQ" "$@" | head -n 1; echo "jq: error: boom" >&2; exit 5 ;;
      modes:-rn) echo "jq: error: boom" >&2; exit 5 ;;
    esac
    exec "$REAL_JQ" "$@"
  SH

  def real_jq
    ENV["PATH"].split(File::PATH_SEPARATOR).map { |d| File.join(d, "jq") }.find { |f| File.executable?(f) }
  end

  # The stub `gh` models the two GitHub APIs as they really answer (checked live, read-only, against
  # public repos on 2026-10-24):
  #   * GET .../git/trees/refs/pull/1/head?recursive=1 returns every entry WITH its git mode: 100644 /
  #     100755 regular files, 120000 a symlink, 160000 a gitlink (submodule), 040000 a directory.
  #     `truncated: true` means the list is incomplete.
  #   * GET .../contents/<path>?ref=... does NOT reveal a symlink to a tracked file. GitHub's docs: "If the
  #     content is a symlink with a normal file target, the API responds with the content of the file", so
  #     it says {"type":"file"} for a mode-120000 entry (django/django docs/_theme/djangodocs-epub/static/
  #     docicons-note.png is 120000 and the contents API says `file`). Only a link to a directory reads as
  #     "symlink". The check must therefore never rest on this endpoint.
  # `modes` maps a path to a git mode string, :absent (no tree entry) or :nomode (an entry without a mode).
  # Anything not named is a regular file (100644).
  MODE_TYPES = { "100644" => "blob", "100755" => "blob", "120000" => "blob", "160000" => "commit", "040000" => "tree" }.freeze

  # The commit the stub says the PR head is, until a test moves it.
  HEAD_SHA = "a" * 40
  OTHER_SHA = "b" * 40

  # `types` overrides the type of a named entry; `extra` appends raw rows (a duplicate path, an entry the
  # file list never named). A mode listed in `modes` as :absent has no entry at all.
  def tree_entries(files, modes, types: {}, extra: [])
    files.reject { |f| f["status"] == "removed" }.filter_map do |f|
      name = f["filename"]
      mode = modes.fetch(name, "100644")
      next if mode == :absent
      next({ "path" => name }) if mode == :nomode
      { "path" => name, "mode" => mode, "type" => types.fetch(name) { MODE_TYPES.fetch(mode, "blob") }, "sha" => "0" * 40 }
    end + extra + [ { "path" => "app", "mode" => "040000", "type" => "tree", "sha" => "1" * 40 } ]
  end

  # The trees API echoes the COMMIT sha it was asked for in `sha` (checked live 2026-10-24: asking for
  # a PR's head commit returns that commit sha, not the tree sha).
  def tree_body(tree, entries, sha: HEAD_SHA)
    case tree
    when :error then "ERROR"
    when :garbage then "not json{"
    when :truncated then JSON.generate({ "sha" => sha, "tree" => entries, "truncated" => true })
    when :no_truncated_key then JSON.generate({ "sha" => sha, "tree" => entries })
    else JSON.generate({ "sha" => sha, "tree" => entries, "truncated" => false })
    end
  end

  # What the real contents API answers for a path with that mode (see the note above: a symlink to a
  # file reads as a file).
  def contents_body(mode)
    case mode
    when "160000" then '{"type":"submodule","path":"x"}'
    when "040000" then '[{"type":"file","path":"x/a"}]'
    else '{"type":"file","path":"x"}'
    end
  end

  def uri_path(path)
    path.split("/", -1).map { |seg| ERB::Util.url_encode(seg) }.join("/")
  end

  def run_classify(files:, classifier: :real, gh_fails: false, changed: nil, jq_fail: nil, modes: {}, tree: :ok, calls: nil,
                   heads: [ HEAD_SHA ], tree_sha: nil, types: {}, extra: [])
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
      tsv = File.join(dir, "stubs", "contents.tsv")
      File.write(tsv, modes.reject { |_, m| m == :absent || m == :nomode }.map { |path, mode| "#{uri_path(path)}\t#{contents_body(mode)}\n" }.join)
      tree_out = File.join(dir, "stubs", "tree.out")
      File.write(tree_out, tree_body(tree, tree_entries(files, modes, types: types, extra: extra), sha: tree_sha || heads.first.to_s))
      # What `GET pulls/N` says the head commit is on the 1st, 2nd, ... read (the last value repeats).
      # :error is a failed call, :garbage a reply that is not a commit sha.
      heads_file = File.join(dir, "stubs", "heads.txt")
      File.write(heads_file, heads.map { |h| h.to_s }.join("\n") + "\n")
      head_count = File.join(dir, "stubs", "head_reads")
      File.write(head_count, "0")
      call_log = File.join(dir, "gh_calls")
      FileUtils.touch(call_log)
      File.write(File.join(dir, "stubs", "gh"), <<~SH)
        #!/bin/sh
        echo "$*" >> #{call_log}
        #{gh_fails ? 'echo "gh: boom" >&2; exit 1' : ''}
        case "$*" in
          *"/pulls/1/files"*) cat #{pages}; exit 0 ;;
          *"/pulls/1"*)
            n=$(( $(cat #{head_count}) + 1 )); echo "$n" > #{head_count}
            total=$(wc -l < #{heads_file}); [ "$n" -gt "$total" ] && n="$total"
            v=$(sed -n "${n}p" #{heads_file})
            if [ "$v" = error ]; then echo "gh: HTTP 500" >&2; exit 1; fi
            if [ "$v" = garbage ]; then v="not-a-sha"; fi
            printf '{"head":{"sha":"%s"}}\n' "$v" | "$REAL_JQ" -r '.head.sha'
            exit $?
            ;;
          *"/git/trees/"*)
            filter=""; prev=""
            for a in "$@"; do
              case "$prev" in --jq) filter="$a" ;; esac
              prev="$a"
            done
            if [ "$(cat #{tree_out})" = ERROR ]; then echo "gh: HTTP 404" >&2; exit 1; fi
            if [ -n "$filter" ]; then "$REAL_JQ" -r "$filter" < #{tree_out}; exit $?; fi
            cat #{tree_out}
            exit 0
            ;;
          *"/contents/"*)
            url=""; filter="."; prev=""
            for a in "$@"; do
              case "$prev" in --jq) filter="$a" ;; esac
              case "$a" in repos/*) url="$a" ;; esac
              prev="$a"
            done
            enc="${url#*/contents/}"; enc="${enc%%\\?*}"
            body=$(awk -F'\t' -v k="$enc" '$1==k {print $2; exit}' #{tsv})
            [ -z "$body" ] && body='{"type":"file","path":"x"}'
            printf '%s\n' "$body" | "$REAL_JQ" -r "$filter"
            exit $?
            ;;
        esac
        cat #{pages}
      SH
      FileUtils.chmod(0o755, File.join(dir, "stubs", "gh"))
      if jq_fail
        File.write(File.join(dir, "stubs", "jq"), JQ_STUB)
        FileUtils.chmod(0o755, File.join(dir, "stubs", "jq"))
      end
      File.write(File.join(dir, "step.sh"), step("classify")["run"])

      summary = File.join(dir, "summary.md")
      output = File.join(dir, "output.txt")
      FileUtils.touch([ summary, output ])
      env = { "PATH" => "#{File.join(dir, 'stubs')}:#{ENV['PATH']}", "GH_TOKEN" => "x", "REPO" => "o/r", "PR" => "1",
              "CHANGED" => (changed || files.size).to_s, "GITHUB_STEP_SUMMARY" => summary, "GITHUB_OUTPUT" => output }
      env["REAL_JQ"] = real_jq
      env["JQ_FAIL"] = jq_fail.to_s if jq_fail
      _out, err, status = Open3.capture3(env, "bash", "step.sh", chdir: dir)
      assert status.success?, "the Classify step itself must not fail: #{err}"
      calls&.concat(File.readlines(call_log, chomp: true))
      [ File.read(output)[/tier=(\S+)/, 1], File.read(summary) ]
    end
  end

  def file(name, previous: nil, status: "modified")
    { "filename" => name, "previous_filename" => previous, "status" => status }.compact
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

  # Copilot round on #633: a file named only with spaces is a changed path. The workflow wrote it
  # to paths.txt and the classifier dropped it as blank, so README.md plus that file was phone-safe.
  test "a file whose name is only spaces makes the PR laptop-only" do
    tier, summary = run_classify(files: [ file("README.md"), file("   ") ])
    assert_equal "laptop-only", tier, summary
  end

  # ---- a safe-named path must be a regular file (panel round on #633) ----------------------
  #
  # The files API gives names and statuses, never file modes. A symlink named logo.png, or docs/x.md,
  # classifies phone-safe by name, and an asset pipeline follows the link when it precompiles. When
  # the classifier says phone-safe, every changed path that still exists must be a regular file
  # (git mode 100644 or 100755) in the PR head's git tree. The tree is read from refs/pull/N/head on the
  # base repo (no head SHA, no head repo), in ONE call. The contents API cannot be used: it reports
  # a symlink to a tracked file as {"type":"file"} (see the note above the stub). Anything other than a
  # regular file, a tree that is truncated or unreadable, or any failed call, is laptop-only.
  def tree_calls(calls) = calls.count { |c| c.include?("/git/trees/") }
  def contents_calls(calls) = calls.count { |c| c.include?("/contents/") }

  test "a safe-named path that is a symlink to a tracked file makes the PR laptop-only" do
    calls = []
    tier, summary = run_classify(files: [ file("README.md"), file("app/assets/images/logo.png") ],
                                 modes: { "app/assets/images/logo.png" => "120000" }, calls: calls)
    assert_equal "laptop-only", tier, summary
    assert_match(/symlink/i, summary)
    assert_equal 0, contents_calls(calls), "the contents API calls a symlink-to-file a file; it must not be asked"
  end

  test "a safe-named doc that is a symlink makes the PR laptop-only" do
    tier, = run_classify(files: [ file("docs/notes.md") ], modes: { "docs/notes.md" => "120000" })
    assert_equal "laptop-only", tier
  end

  test "a safe-named path that is a submodule (gitlink) makes the PR laptop-only" do
    tier, summary = run_classify(files: [ file("docs/vendor.md") ], modes: { "docs/vendor.md" => "160000" })
    assert_equal "laptop-only", tier, summary
    assert_match(/submodule/i, summary)
  end

  test "a safe-named path that is a directory makes the PR laptop-only" do
    tier, = run_classify(files: [ file("docs/odd.md") ], modes: { "docs/odd.md" => "040000" })
    assert_equal "laptop-only", tier
  end

  test "a path with an unknown mode makes the PR laptop-only" do
    tier, = run_classify(files: [ file("docs/odd.md") ], modes: { "docs/odd.md" => "100664" })
    assert_equal "laptop-only", tier
  end

  test "a path that is not in the PR head's tree makes the PR laptop-only" do
    tier, summary = run_classify(files: [ file("README.md"), file("docs/ghost.md") ], modes: { "docs/ghost.md" => :absent })
    assert_equal "laptop-only", tier, summary
    assert_match(/not found|not in/i, summary)
  end

  test "a tree entry with no mode makes the PR laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], modes: { "README.md" => :nomode })
    assert_equal "laptop-only", tier
  end

  test "a truncated tree makes the PR laptop-only, not 'nothing wrong'" do
    tier, summary = run_classify(files: [ file("README.md") ], tree: :truncated)
    assert_equal "laptop-only", tier, summary
    assert_match(/truncated|incomplete/i, summary)
  end

  test "a tree call that fails makes the PR laptop-only, not 'nothing wrong'" do
    tier, summary = run_classify(files: [ file("README.md") ], tree: :error)
    assert_equal "laptop-only", tier, summary
    assert_match(/undetermined/i, summary)
  end

  test "a tree reply that is not JSON makes the PR laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], tree: :garbage)
    assert_equal "laptop-only", tier
  end

  test "one symlink among regular files makes the PR laptop-only" do
    tier, = run_classify(files: [ file("README.md"), file("docs/a.md"), file("docs/b.md") ], modes: { "docs/b.md" => "120000" })
    assert_equal "laptop-only", tier
  end

  test "regular files (100644 and 100755) at the PR head keep a docs-only PR phone-safe" do
    tier, summary = run_classify(files: [ file("README.md"), file("docs/a.md"), file("docs/run.md") ],
                                 modes: { "docs/run.md" => "100755" })
    assert_equal "phone-safe", tier, summary
  end

  test "a renamed file is checked under its new name" do
    tier, = run_classify(files: [ file("docs/new.md", previous: "docs/old.md", status: "renamed") ], modes: { "docs/new.md" => "120000" })
    assert_equal "laptop-only", tier
  end

  test "a renamed file's old name is not looked up: it no longer exists at the head" do
    tier, summary = run_classify(files: [ file("docs/new.md", previous: "docs/old.md", status: "renamed") ])
    assert_equal "phone-safe", tier, summary
  end

  test "a removed file needs no entry in the tree, because it no longer exists at the head" do
    tier, summary = run_classify(files: [ file("README.md"), file("docs/gone.md", status: "removed") ])
    assert_equal "phone-safe", tier, summary
  end

  test "a PR that only removes files makes no tree call" do
    calls = []
    tier, summary = run_classify(files: [ file("docs/gone.md", status: "removed") ], calls: calls)
    assert_equal "phone-safe", tier, summary
    assert_equal 0, tree_calls(calls), calls.inspect
  end

  test "a file name with a space is matched by its exact tree path" do
    tier, summary = run_classify(files: [ file("docs/my notes.md") ])
    assert_equal "phone-safe", tier, summary
  end

  # ---- one head commit for the file list and the tree (panel round on #633) -----------------
  #
  # The file list comes from pulls/N/files and the tree from the git trees API, two calls. A push between
  # them leaves a list for one commit and a tree for another: a symlink the list never named, or a file the
  # list calls regular that the tree already shows as a link. So the workflow reads the PR's head commit
  # (API data, never checked out or executed) BEFORE listing the files, asks for the tree BY THAT COMMIT,
  # requires the tree reply to echo it, and reads the head again afterwards: anything other than the same
  # 40-hex commit all the way through is laptop-only.
  def head_reads(calls) = calls.count { |c| c =~ %r{repos/o/r/pulls/1(\s|$)} && c !~ /files/ }

  test "the tree is asked for by the head commit read from the API, not by a moving ref" do
    calls = []
    tier, summary = run_classify(files: [ file("README.md") ], calls: calls)
    assert_equal "phone-safe", tier, summary
    lookup = calls.find { |c| c.include?("/git/trees/") }
    assert lookup, calls.inspect
    assert_match(%r{repos/o/r/git/trees/#{HEAD_SHA}\?recursive=1}, lookup)
    refute_match(%r{refs/pull}, lookup)
  end

  test "the head commit is read before the files and again after the tree" do
    calls = []
    run_classify(files: [ file("README.md") ], calls: calls)
    idx = ->(pat) { calls.index { |c| c =~ pat } }
    first_head = calls.index { |c| c =~ %r{repos/o/r/pulls/1(\s|$)} && c !~ /files/ }
    last_head = calls.rindex { |c| c =~ %r{repos/o/r/pulls/1(\s|$)} && c !~ /files/ }
    assert_operator head_reads(calls), :>=, 2, calls.inspect
    assert_operator first_head, :<, idx.(%r{pulls/1/files}), calls.inspect
    assert_operator last_head, :>, idx.(%r{/git/trees/}), calls.inspect
  end

  test "a head that moves while the PR is judged makes it laptop-only, tree newer than the list" do
    tier, summary = run_classify(files: [ file("README.md") ], heads: [ HEAD_SHA, OTHER_SHA ])
    assert_equal "laptop-only", tier, summary
    assert_match(/moved|changed/i, summary)
  end

  test "a tree for a different commit than the one asked for is laptop-only (tree older than the list)" do
    tier, summary = run_classify(files: [ file("app/assets/images/logo.png") ], tree_sha: OTHER_SHA)
    assert_equal "laptop-only", tier, summary
    assert_match(/commit|head|tree/i, summary)
  end

  test "a head commit that cannot be read makes the PR laptop-only" do
    tier, summary = run_classify(files: [ file("README.md") ], heads: [ :error ])
    assert_equal "laptop-only", tier, summary
    assert_match(/undetermined/i, summary)
  end

  test "a head commit that is not a 40-hex sha makes the PR laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], heads: [ :garbage ])
    assert_equal "laptop-only", tier
  end

  test "a head commit that cannot be re-read after the tree makes the PR laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], heads: [ HEAD_SHA, :error ])
    assert_equal "laptop-only", tier
  end

  test "a PR that only removes files still checks the head did not move while its list was read" do
    tier, summary = run_classify(files: [ file("docs/gone.md", status: "removed") ], heads: [ HEAD_SHA, OTHER_SHA ])
    assert_equal "laptop-only", tier, summary
  end

  # ---- guards that had no test (panel round on #633) --------------------------------------
  test "a mode check whose jq dies makes the PR laptop-only, never 'nothing wrong'" do
    tier, summary = run_classify(files: [ file("README.md") ], jq_fail: :modes)
    assert_equal "laptop-only", tier, summary
    assert_match(/undetermined/i, summary)
  end

  test "a tree reply with no truncated field is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], tree: :no_truncated_key)
    assert_equal "laptop-only", tier
  end

  test "a tree that lists one path twice is laptop-only, whichever entry comes last" do
    dup = [ { "path" => "docs/dup.md", "mode" => "120000", "type" => "blob", "sha" => "2" * 40 } ]
    tier, summary = run_classify(files: [ file("docs/dup.md") ], extra: dup)
    assert_equal "laptop-only", tier, summary
  end

  test "a tree that lists a symlink first and a regular file second for one path is laptop-only" do
    # from_entries would keep the LAST row; the symlink must not be able to hide behind it
    dup = [ { "path" => "docs/dup.md", "mode" => "100644", "type" => "blob", "sha" => "2" * 40 } ]
    tier, = run_classify(files: [ file("docs/dup.md") ], modes: { "docs/dup.md" => "120000" }, extra: dup)
    assert_equal "laptop-only", tier
  end

  test "a regular mode on an entry that is not a blob is laptop-only" do
    tier, = run_classify(files: [ file("docs/odd.md") ], types: { "docs/odd.md" => "commit" })
    assert_equal "laptop-only", tier
  end

  test "a laptop-only classification makes no tree or contents calls" do
    calls = []
    run_classify(files: [ file("README.md"), file("app/models/lakeraven/ehr/disclosure.rb") ], calls: calls)
    assert_equal 0, tree_calls(calls), calls.inspect
    assert_equal 0, contents_calls(calls), calls.inspect
  end

  test "any number of existing safe paths is verified with ONE tree call and stays phone-safe" do
    files = (1..150).map { |i| file("docs/n#{i}.md") }
    calls = []
    tier, summary = run_classify(files: files, calls: calls)
    assert_equal "phone-safe", tier, summary
    assert_equal 1, tree_calls(calls), calls.inspect
    assert_equal 0, contents_calls(calls), calls.inspect
  end

  test "one symlink among many safe paths is found" do
    files = (1..150).map { |i| file("docs/n#{i}.md") }
    tier, = run_classify(files: files, modes: { "docs/n77.md" => "120000" })
    assert_equal "laptop-only", tier
  end

  test "a jq that dies while listing the existing paths is laptop-only" do
    tier, summary = run_classify(files: [ file("README.md") ], jq_fail: :existing)
    assert_equal "laptop-only", tier, summary
  end

  # ---- duplicate names pass the count check (panel round on #633) --------------------------
  #
  # [README.md, README.md] has the right length for CHANGED=2, but a second real file was never
  # seen (the head moved mid-pagination). The names must be distinct as well as the right number.
  test "a file list with a repeated name is laptop-only even when its length matches" do
    tier, summary = run_classify(files: [ file("README.md"), file("README.md") ])
    assert_equal "laptop-only", tier, summary
    assert_match(/duplicate|repeated|distinct/i, summary)
  end

  test "distinct names of the right count are still phone-safe" do
    tier, = run_classify(files: [ file("README.md"), file("CHANGELOG.md") ])
    assert_equal "phone-safe", tier
  end

  # Copilot round on #633: a jq that dies must never read as "no control characters" or as a
  # complete list of names. Both used to fall through to phone-safe.
  test "a control-character check that errors is laptop-only, not 'no control characters'" do
    tier, summary = run_classify(files: [ file("README.md") ], jq_fail: :check)
    assert_equal "laptop-only", tier
    assert_match(/undetermined/i, summary)
  end

  test "a name extraction that dies halfway is laptop-only, not the half that was written" do
    tier, summary = run_classify(files: [ file("README.md"), file("app/models/lakeraven/ehr/disclosure.rb") ], jq_fail: :extract)
    assert_equal "laptop-only", tier
    assert_match(/undetermined/i, summary)
  end

  test "a file list that cannot be merged is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], jq_fail: :slurp)
    assert_equal "laptop-only", tier
  end

  test "a file count that cannot be taken is laptop-only" do
    tier, = run_classify(files: [ file("README.md") ], jq_fail: :count)
    assert_equal "laptop-only", tier
  end

  test "the stand-in jq changes nothing when it is not told to fail (the guard is honest)" do
    tier, = run_classify(files: [ file("README.md") ], jq_fail: :none)
    assert_equal "phone-safe", tier
  end

  # ---- when it runs ---------------------------------------------------------------------

  # Retargeting a PR emits `edited`. The new base can put controllers or migrations into a
  # diff that was docs-only, so the label has to be recomputed.
  test "a change of the PR's base branch reclassifies it" do
    assert_includes triggers.dig("pull_request_target", "types"), "edited"
  end

  # The concurrency group cancels an in-flight run when a new one starts. A job-level `if`
  # that then skips the new run (say, a title edit) would cancel a real classification and
  # replace it with nothing, so the job must always run.
  test "the job has no condition that could skip the run that cancelled another" do
    refute workflow.dig("jobs", "risk-tier").key?("if")
  end

  # ---- the Apply and Verify steps, executed -----------------------------------------------

  LABEL_GH = <<~'SH'
    #!/bin/sh
    # Stub gh: labels live in $GH_STATE, one per line; every call is appended to $GH_LOG.
    echo "$*" >> "$GH_LOG"
    # Like the real gh: `label create <name>` takes only --color, --description (both with a
    # non-empty value) and --force. Anything else is "unknown flag", which is what a mangled
    # flag in the workflow does under `set -e`.
    check_label_create() {
      shift 2
      case "${1:-}" in ""|-*) echo "gh: label name required" >&2; return 1 ;; esac
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --force) shift ;;
          --color|--description)
            if [ -z "${2:-}" ]; then echo "gh: flag needs an argument: $1" >&2; return 1; fi
            shift 2 ;;
          *) echo "unknown flag: $1" >&2; return 1 ;;
        esac
      done
    }
    if [ "$1 $2" = "label create" ]; then check_label_create "$@" || exit 1; fi
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
      "pr view")
        if [ -n "$GH_FAIL_VIEW" ]; then echo "gh: cannot read the PR" >&2; exit 1; fi
        jq -n --rawfile s "$GH_STATE" '{labels: ($s | split("\n") | map(select(length > 0)) | map({name: .}))}' | jq -r "$jqexpr" ;;
    esac
    exit 0
  SH

  # Runs the named steps in order against the stub. Returns [exit statuses, final labels, log].
  def run_label_steps(step_names, tier:, labels: [], fail_remove: false, fail_add: false, fail_view: false)
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
      env["GH_FAIL_VIEW"] = "1" if fail_view
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

  test "Apply gives every label it creates a non-empty description" do
    body = step("Apply the label")["run"].gsub(/\\\n\s*/, " ")
    creates = body.lines.select { |l| l =~ /\bgh label create\b/ }
    assert_equal 2, creates.size
    creates.each do |l|
      assert_match(/--description\s+"[^"]{10,}"/, l, "label create without a real --description: #{l.strip}")
    end
  end

  test "no label description claims locale files are phone-safe" do
    body = step("Apply the label")["run"].gsub(/\\\n\s*/, " ")
    creates = body.lines.select { |l| l =~ /\bgh label create\b/ }
    assert_equal 2, creates.size
    creates.each do |l|
      refute_match(/locale/i, l, "locale YAML can run Ruby when I18n loads it, so it is not on the safe-list: #{l.strip}")
    end
  end

  test "no label description claims stylesheets are phone-safe" do
    body = step("Apply the label")["run"].gsub(/\\\n\s*/, " ")
    creates = body.lines.select { |l| l =~ /\bgh label create\b/ }
    assert_equal 2, creates.size
    creates.each do |l|
      refute_match(/stylesheet|\bcss\b/i, l, "a stylesheet can leak a CSRF token or hide a safety prompt, so it is not phone-safe: #{l.strip}")
    end
  end

  # ---- a stale risk:phone-safe must not outlive the run that started (panel round) -----------
  STALE = "Drop a stale phone-safe label"

  test "the stale-label step is the first thing that runs after checkout, before Classify" do
    run_steps = steps.select { |s| s.key?("run") }
    assert_equal STALE, run_steps.first["name"]
    assert_operator steps.index { |s| s["name"] == STALE }, :<, steps.index { |s| s["name"] == "Classify" }
  end

  test "the stale-label step cannot be skipped or swallowed" do
    refute step(STALE).key?("continue-on-error")
    refute step(STALE).key?("if")
  end

  test "the stale-label step removes risk:phone-safe and nothing else" do
    statuses, labels, log = run_label_steps([ STALE ], tier: "phone-safe", labels: [ "risk:phone-safe", "risk:laptop-only", "bug" ])
    assert_equal [ 0 ], statuses
    assert_equal [ "bug", "risk:laptop-only" ], labels
    assert(log.any? { |l| l.include?("--remove-label risk:phone-safe") }, log.inspect)
    refute(log.any? { |l| l.include?("--add-label") }, log.inspect)
  end

  test "the stale-label step succeeds when there is no label to remove" do
    statuses, labels, = run_label_steps([ STALE ], tier: "laptop-only", labels: [ "bug" ])
    assert_equal [ 0 ], statuses
    assert_equal [ "bug" ], labels
  end

  test "the stale-label step carries on when the removal fails but the label is confirmed gone" do
    statuses, = run_label_steps([ STALE ], tier: "phone-safe", labels: [ "bug" ], fail_remove: true)
    assert_equal [ 0 ], statuses
  end

  test "the stale-label step fails, and leaves the labels, when the removal fails and the label is still there" do
    statuses, labels, = run_label_steps([ STALE ], tier: "phone-safe", labels: [ "risk:phone-safe" ], fail_remove: true)
    assert_equal [ 1 ], statuses
    assert_equal [ "risk:phone-safe" ], labels
  end

  test "the stale-label step fails when the removal fails and the labels cannot be read" do
    statuses, = run_label_steps([ STALE ], tier: "phone-safe", labels: [ "risk:phone-safe" ], fail_remove: true, fail_view: true)
    assert_equal [ 1 ], statuses
  end

  test "Apply removes a stale opposite label that was set before this run" do
    statuses, labels, log = run_label_steps([ "Apply the label" ], tier: "laptop-only", labels: [ "risk:phone-safe", "risk:laptop-only" ])
    assert_equal [ 0 ], statuses, "Apply must succeed: #{log.inspect}"
    assert_equal [ "risk:laptop-only" ], labels.uniq # the stub appends; real GitHub de-duplicates
    assert(log.any? { |l| l.include?("--remove-label risk:phone-safe") }, "the stale label must be removed: #{log.inspect}")
  end

  test "every gh call in the workflow uses only flags the workflow is known to need" do
    allowed = %w[--color --description --force --jq --json --add-label --remove-label --repo --paginate]
    steps.each do |st|
      next unless st["run"]

      st["run"].gsub(/\\\n\s*/, " ").lines.select { |l| l =~ /\bgh (api|pr|label|run|issue)\b/ }.each do |l|
        flags = l.scan(/(?<=\s)--[A-Za-z][\w-]*/).uniq
        unknown = flags - allowed
        assert_empty unknown, "unknown gh flag(s) #{unknown.inspect} in step #{st['name'].inspect}: #{l.strip}"
      end
    end
  end

  test "the workflow carries no placeholder tokens" do
    text = File.read(WORKFLOW)
    refute_match(/(?<![A-Za-z])(XX+|TODO|FIXME|TBD)(?![A-Za-z])/, text)
  end

  test "Apply fails and adds nothing when the stale opposite label cannot be removed" do
    statuses, labels, log = run_label_steps([ "Apply the label", "Verify the label" ], tier: "laptop-only",
                                           labels: [ "risk:phone-safe" ], fail_remove: true)
    assert_operator statuses.first, :>, 0, "Apply must fail visibly"
    assert_equal [ "risk:phone-safe" ], labels, "it must not leave a PR carrying both labels"
    refute(log.any? { |l| l.include?("--add-label") }, "nothing may be added after a failed removal")
    assert_operator statuses.last, :>, 0, "Verify must also fail: the PR is still mislabeled"
  end

  # Copilot round on #633: when the removal fails, the label read decides whether to go on.
  # A read that also fails is not "the label is gone".
  test "Apply stops, adding nothing, when the removal fails and the labels cannot be read" do
    statuses, labels, log = run_label_steps([ "Apply the label" ], tier: "laptop-only",
                                           labels: [ "risk:phone-safe" ], fail_remove: true, fail_view: true)
    assert_operator statuses.first, :>, 0, "Apply must fail visibly"
    assert_equal [ "risk:phone-safe" ], labels
    refute(log.any? { |l| l.include?("--add-label") }, "nothing may be added when the labels are unreadable: #{log.inspect}")
  end

  test "Apply goes on when the removal fails but a successful read shows the label is already gone" do
    statuses, labels, = run_label_steps([ "Apply the label" ], tier: "laptop-only", labels: [], fail_remove: true)
    assert_equal [ 0 ], statuses
    assert_equal [ "risk:laptop-only" ], labels
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
