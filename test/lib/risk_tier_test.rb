# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# Contract for bin/risk-tier, the script behind the "Risk tier" label.
#
#   bin/risk-tier                 paths on stdin, one per line
#   bin/risk-tier --base REF      paths from `git diff --no-renames --name-only REF...HEAD`
#   bin/risk-tier --coverage      paths on stdin; prints "<count>\t<glob>" for every rule
#
# First line of output is "laptop-only" or "phone-safe". Every path that made a PR
# laptop-only follows as "  <path>  <- <rule>".
#
# The rules file is a SAFE-LIST with laptop-only overrides. A PR is phone-safe only if EVERY
# changed path matches a glob in the `[safe]` section AND matches no laptop-only rule. A path
# on neither list is laptop-only ("not on the safe-list"). Gate round 2 on #633 showed why: a
# blocklist of sensitive names cannot see a privileged file with an unremarkable name
# (web_controller.rb, patients_controller.rb, test_helper.rb), so the default has to be the
# cautious tier. An empty or undeterminable list is laptop-only with exit 2: absence of data
# is never verification. It labels; it does not gate, so a classified PR exits 0 either way.
class RiskTierTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "risk-tier")
  RULES = File.join(ROOT, ".github", "risk-tiers.txt")

  def run_script(*args, stdin: "", chdir: ROOT)
    Open3.capture3(SCRIPT, *args, stdin_data: stdin, chdir: chdir)
  end

  def classify(paths)
    out, _err, status = run_script(stdin: Array(paths).join("\n") + "\n")
    [ out.lines.first.to_s.strip, status.exitstatus, out ]
  end

  PHONE_SAFE = [
    "README.md",
    "./README.md",
    "CHANGELOG.md",
    "docs/BPRM_PARITY_PLAN.md",
    "docs/my notes.md",
    "docs/demo_patient_chart_runbook.md"
  ].freeze

  # Not on the safe-list, and matching no laptop-only rule: laptop-only by default. These are
  # the paths gate round 2 showed a blocklist classifying phone-safe, plus the ordinary
  # code, tests, features and config that used to be phone-safe by omission.
  UNLISTED = [
    "app/views/lakeraven/ehr/dashboards/show.html.erb",
    "app/views/lakeraven/ehr/charts/show.html.erb",
    "app/views/lakeraven/ehr/screenings/index.html.erb",
    "app/helpers/lakeraven/ehr/application_helper.rb",
    "app/controllers/lakeraven/ehr/web_controller.rb",
    "app/controllers/lakeraven/ehr/patients_controller.rb",
    "app/controllers/lakeraven/ehr/patient_contexts_controller.rb",
    "app/controllers/lakeraven/ehr/transitions_of_care_controller.rb",
    "app/controllers/lakeraven/ehr/charts_controller.rb",
    "app/controllers/lakeraven/ehr/demo_visits_controller.rb",
    "app/services/lakeraven/ehr/fhir/patient_serializer.rb",
    "test/test_helper.rb",
    "test/controllers/lakeraven/ehr/transitions_of_care_controller_test.rb",
    "features/onc/transitions_of_care.feature",
    "test/integration/patient_search_total_test.rb",
    "config/measures/bmi_screening.yml",
    "app/terminology/lakeraven/ehr/example_code_system.rb",
    "features/fhir/patient.feature",
    "features/onc/vital_signs_compliance.feature",
    "app/views/lakeraven/ehr/screenings/show.json.jbuilder",
    "app/views/lakeraven/ehr/charts/helper.rb",
    "app/helpers/lakeraven/ehr/application_helper.txt",
    "docs/diagram.png",
    "docs/script.rb",
    "config/locales/en.rb",
    "app/assets/javascripts/lakeraven/ehr/application.js",
    "app/assets/stylesheets/lakeraven/ehr/application.js",
    "Rakefile.txt",
    "cucumber.yml",
    ".rubocop.yml",
    ".gitignore"
  ].freeze

  # Views that carry more than display: the layout emits the CSRF and CSP meta tags, and the
  # sign-in and patient-context views post the forms those controllers authorize. They sit
  # under app/views/**; views are not on the safe-list at all, so these also match a rule that
  # names why they are sensitive.
  SENSITIVE_VIEWS = [
    "app/views/lakeraven/ehr/consent/new.html.erb",
    "app/helpers/lakeraven/ehr/session_helper.rb",
    "app/views/layouts/lakeraven/ehr/application.html.erb",
    "app/views/lakeraven/ehr/sessions/new.html.erb",
    "app/views/lakeraven/ehr/patient_contexts/new.html.erb"
  ].freeze

  # Safe by glob, laptop-only by override: a rule always wins over the safe-list.
  SAFE_BUT_OVERRIDDEN = [
    "docs/adr/0001-anything.md",
    "docs/compliance/notes.md",
    "docs/certification/matrix.md",
    "docs/token rotation.md",
    "docs/part2-overview.md",
    "docs/audit-trail.md",
    "config/locales/oauth.en.yml"
  ].freeze

  LAPTOP_ONLY = [
    ".github/workflows/ci.yml",
    ".github/risk-tiers.txt",
    ".github/CODEOWNERS",
    "bin/risk-tier",
    "Gemfile",
    "Gemfile.lock",
    "lakeraven-ehr.gemspec",
    "db/migrate/20260421090000_create_audit_events.rb",
    "test/dummy/db/schema.rb",
    "test/dummy/config/initializers/doorkeeper.rb",
    "config/routes.rb",
    "app/services/lakeraven/ehr/authentication_service.rb",
    "app/controllers/concerns/lakeraven/ehr/smart_authentication.rb",
    "app/services/lakeraven/ehr/client_jwks.rb",
    "app/policies/lakeraven/ehr/patient_policy.rb",
    "app/services/lakeraven/ehr/session_scope_policy.rb",
    "app/models/lakeraven/ehr/consent.rb",
    "app/services/lakeraven/ehr/part2_egress_filter.rb",
    "app/services/lakeraven/ehr/fhir/redaction_policy.rb",
    "app/models/lakeraven/ehr/audit_event.rb",
    "app/models/lakeraven/ehr/organization.rb",
    "app/models/lakeraven/ehr/bulk_export.rb",
    "docs/adr/0008-binding-a-request-to-its-tenant-client.md",
    "docs/compliance/part2-disclosure-surface-audit.md",
    "SECURITY.md",
    "test/controllers/lakeraven/ehr/organization_boundary_test.rb",
    "features/part2_disclosure_gate.feature",
    "docs/consent form.md",
    "app/controllers/lakeraven/ehr/backend_services_controller.rb",
    "test/controllers/lakeraven/ehr/backend_services_controller_test.rb",
    "app/models/concerns/lakeraven/ehr/backend_client_registration.rb",
    "app/models/lakeraven/ehr/backend_assertion_jti.rb",
    "app/services/lakeraven/ehr/assertion_replay_guard.rb",
    "app/controllers/lakeraven/ehr/smart_launch_controller.rb",
    "app/models/lakeraven/ehr/launch_context.rb",
    "app/services/lakeraven/ehr/login_throttle.rb",
    "app/models/lakeraven/ehr/kernel_user.rb",
    "app/models/lakeraven/ehr/current_user.rb",
    "app/gateways/lakeraven/ehr/site_gateway.rb",
    "app/gateways/lakeraven/ehr/e_signature_gateway.rb",
    "app/controllers/lakeraven/ehr/application_controller.rb",
    "app/controllers/concerns/lakeraven/ehr/clinician_patient_context.rb",
    "lib/lakeraven/ehr/engine.rb",
    "app/controllers/concerns/lakeraven/ehr/export_ownership.rb",
    "app/controllers/lakeraven/ehr/exports_controller.rb",
    "app/controllers/lakeraven/ehr/export_files_controller.rb",
    "test/controllers/lakeraven/ehr/exports_controller_test.rb",
    "app/services/lakeraven/ehr/ehi_export_service.rb",
    "test/services/lakeraven/ehr/ehi_export_service_test.rb",
    "features/onc/ehi_export.feature",
    "app/models/lakeraven/ehr/disclosure.rb",
    "app/services/lakeraven/ehr/disclosure_service.rb",
    "test/models/lakeraven/ehr/disclosure_test.rb",
    "test/services/lakeraven/ehr/disclosure_service_test.rb",
    "features/onc/accounting_of_disclosures.feature",
    "features/step_definitions/onc_accounting_of_disclosures_steps.rb",
    "test/integration/fhir_api_authorization_test.rb",
    "app/models/lakeraven/ehr/security_incident.rb",
    "test/models/lakeraven/ehr/security_incident_test.rb",
    "features/breach_detection.feature",
    "features/step_definitions/breach_detection_steps.rb",
    "app/models/lakeraven/ehr/amendment_request.rb",
    "app/services/lakeraven/ehr/amendment_service.rb",
    "test/models/lakeraven/ehr/amendment_request_test.rb",
    "test/services/lakeraven/ehr/amendment_service_test.rb",
    "features/onc/patient_amendments.feature",
    "features/rate_limiting.feature",
    "app/services/lakeraven/ehr/vaers_export_service.rb",
    "features/vaers_export.feature",
    "app/services/lakeraven/ehr/qrda/category_one_exporter.rb",
    "app/services/lakeraven/ehr/qrda/category_three_exporter.rb",
    "test/dummy/app/controllers/csrf_probe_controller.rb",
    "test/dummy/app/controllers/csrf_disabled_probe_controller.rb",
    "features/bh_access_clock.feature",
    "app/services/lakeraven/ehr/reportability_response_processor.rb",
    "app/services/lakeraven/ehr/referral_origination_service.rb",
    "./.github/workflows/ci.yml"
  ].freeze

  # A safe glob's `*` stops at a slash (gate round 4): `docs/*.md` is top-level docs only, not
  # every markdown file in every subtree. Each of these used to be phone-safe because `*`
  # crossed `/`; none matches a laptop-only rule, so "not on the safe-list" is the only thing
  # standing between them and a phone merge.
  NESTED_UNLISTED = [
    "docs/internal/master_key.md",
    "docs/internal/auth_bypass.md",
    "docs/a/b/c.md",
    "docs/runbooks/x.md",
    "app/assets/stylesheets/x/y/z/w.css",
    "app/assets/stylesheets/lakeraven/ehr/sub/extra.css",
    "app/assets/stylesheets/application.css",
    "config/locales/evil/deep.yml"
  ].freeze

  NESTED_UNLISTED.each_with_index do |path, i|
    test "a safe glob does not reach into subtrees ##{i}: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier
      assert_equal 0, status
      assert_includes out, path
      assert_match(/<- .*not on the safe-list/i, out, "output must say the path is not on the safe-list")
    end
  end

  PHONE_SAFE.each_with_index do |path, i|
    test "phone-safe path ##{i}: #{path}" do
      tier, status, = classify(path)
      assert_equal "phone-safe", tier
      assert_equal 0, status
    end
  end

  LAPTOP_ONLY.each_with_index do |path, i|
    test "laptop-only path ##{i}: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier
      assert_equal 0, status
      assert_includes out, path.delete_prefix("./"), "output must name the matched path"
      assert_match(/<- \S/, out, "output must name the rule that matched")
    end
  end

  UNLISTED.each_with_index do |path, i|
    test "unlisted path ##{i} is laptop-only by default: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier
      assert_equal 0, status
      assert_includes out, path
      assert_match(/<- .*safe-list/i, out, "output must say the path is not on the safe-list")
    end
  end

  SENSITIVE_VIEWS.each_with_index do |path, i|
    test "view with more than display ##{i} is laptop-only: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier
      assert_equal 0, status
      assert_includes out, path
    end
  end

  SAFE_BUT_OVERRIDDEN.each_with_index do |path, i|
    test "a laptop-only rule overrides the safe-list ##{i}: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier
      assert_equal 0, status
      refute_match(/safe-list/i, out, "this path matches a laptop-only rule; it should be reported against that rule")
    end
  end

  test "one unlisted path makes an otherwise safe PR laptop-only and only it is listed" do
    tier, status, out = classify([ "README.md", "docs/BPRM_PARITY_PLAN.md", "app/controllers/lakeraven/ehr/web_controller.rb" ])
    assert_equal "laptop-only", tier
    assert_equal 0, status
    assert_includes out, "app/controllers/lakeraven/ehr/web_controller.rb"
    refute_includes out, "README.md"
    refute_includes out, "BPRM_PARITY_PLAN"
  end

  test "a PR of only safe paths is phone-safe and says how many were read" do
    tier, status, out = classify([ "README.md", "docs/BPRM_PARITY_PLAN.md", "CHANGELOG.md" ])
    assert_equal "phone-safe", tier
    assert_equal 0, status
    assert_match(/3 path/, out)
  end

  test "a path with a control character is laptop-only, whatever the rest of it says" do
    [ "docs/a\u0001b.md", "docs/a\rb.md", "docs/a\tb.md", "docs/a\u007fb.md", "docs/a\u001bb.md" ].each do |path|
      tier, status, out = classify([ "README.md", path ])
      assert_equal "laptop-only", tier, path.inspect
      assert_equal 0, status, path.inspect
      assert_match(/control character/i, out, path.inspect)
    end
  end

  # Copilot round on #633: a name made only of whitespace is a real file name, not a blank line.
  # It used to be dropped before classification, so README.md plus a file called "   " came out
  # phone-safe although one changed path was never judged.
  test "a path made only of spaces is laptop-only, not silently dropped" do
    [ " ", "   ", "\u3000" ].each do |name|
      tier, status, out = classify([ "README.md", name ])
      assert_equal "laptop-only", tier, name.inspect
      assert_equal 0, status, name.inspect
      assert_match(/not on the safe-list/, out, name.inspect)
    end
  end

  test "a path made only of a tab is laptop-only, not silently dropped" do
    tier, status, out = classify([ "README.md", "\t" ])
    assert_equal "laptop-only", tier
    assert_equal 0, status
    assert_match(/control character/i, out)
  end

  test "a list holding only a whitespace-only name is classified, not treated as empty" do
    tier, status, out = classify([ "   " ])
    assert_equal "laptop-only", tier
    assert_equal 0, status, "one path was read, so this is a classification (exit 0), not an empty list (exit 2)"
    assert_match(/1 path|not on the safe-list/, out)
  end

  test "genuinely empty lines are still ignored" do
    out, _err, status = run_script(stdin: "README.md\n\n\nCHANGELOG.md\n\n")
    assert_equal "phone-safe", out.lines.first.strip, out
    assert_equal 0, status.exitstatus
    assert_match(/2 path/, out)
  end

  test "a CRLF blank line is still ignored, and a CRLF line keeps its name" do
    out, _err, status = run_script(stdin: "README.md\r\n\r\nCHANGELOG.md\r\n")
    assert_equal "phone-safe", out.lines.first.strip, out
    assert_equal 0, status.exitstatus
  end

  test "whitespace around a real name is part of the name and never trims into a safe match" do
    [ " docs/a.md", "docs/a.md ", " README.md", "README.md " ].each do |name|
      tier, _status, out = classify([ name ])
      assert_equal "laptop-only", tier, name.inspect
      assert_match(/not on the safe-list/, out, name.inspect)
    end
  end

  test "git mode: a file whose name is only spaces makes the PR laptop-only" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      git.call("checkout", "-q", "-b", "topic")
      File.write(File.join(dir, "README.md"), "y\n")
      File.write(File.join(dir, "   "), "z\n")
      commit_all(git, "edit readme and add a blank-named file")
      out, _err, status = run_script("--base", "main", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip, out
      assert_equal 0, status.exitstatus
    end
  end

  test "a rules file with no safe-list section can never produce phone-safe: exit 2" do
    Dir.mktmpdir do |dir|
      rules = File.join(dir, "rules.txt")
      File.write(rules, "Gemfile   # dependencies\n")
      out, _err, status = run_script("--rules", rules, stdin: "README.md\n")
      assert_equal "laptop-only", out.lines.first.to_s.strip
      assert_equal 2, status.exitstatus
    end
  end

  test "a custom rules file: only the safe section's globs are phone-safe and laptop rules still win" do
    Dir.mktmpdir do |dir|
      rules = File.join(dir, "rules.txt")
      File.write(rules, "Gemfile   # dependencies\nfoo/secret*   # secrets\n\n[safe]\nfoo/*.txt   # plain text\n")
      assert_equal "phone-safe", run_script("--rules", rules, stdin: "foo/a.txt\n")[0].lines.first.strip
      assert_equal "laptop-only", run_script("--rules", rules, stdin: "foo/b.rb\n")[0].lines.first.strip
      assert_equal "laptop-only", run_script("--rules", rules, stdin: "foo/secret.txt\n")[0].lines.first.strip
      assert_equal "laptop-only", run_script("--rules", rules, stdin: "foo/a.txt\nGemfile\n")[0].lines.first.strip
    end
  end

  test "in a safe glob `*` and `?` never match a slash; in a laptop rule `*` still crosses it" do
    Dir.mktmpdir do |dir|
      rules = File.join(dir, "rules.txt")
      File.write(rules, "Gemfile   # dependencies\nfoo/secret*   # secrets\n\n[safe]\nfoo/*.txt   # plain text\nbar/*/baz.md   # one level\nq/a?b.txt   # one char\n")
      tier = ->(path) { run_script("--rules", rules, stdin: "#{path}\n")[0].lines.first.strip }
      assert_equal "phone-safe", tier.call("foo/a.txt")
      assert_equal "laptop-only", tier.call("foo/sub/a.txt"), "foo/*.txt must not reach foo/sub/a.txt"
      assert_equal "laptop-only", tier.call("foo/a/b/c.txt")
      assert_equal "phone-safe", tier.call("bar/x/baz.md")
      assert_equal "laptop-only", tier.call("bar/x/y/baz.md"), "bar/*/baz.md is exactly one level"
      assert_equal "laptop-only", tier.call("bar/baz.md"), "bar/*/baz.md needs the middle segment"
      assert_equal "phone-safe", tier.call("q/axb.txt")
      assert_equal "laptop-only", tier.call("q/a/b.txt"), "? must not match a slash"
      assert_equal "phone-safe", tier.call("FOO/A.TXT"), "matching stays case-insensitive"
      assert_equal "laptop-only", tier.call("foo/secret/dir/x.txt"), "laptop rules keep their crossing semantics"
    end
  end

  # Hard-coded, not derived from the rules (deriving it would be circular): the tracked paths
  # that are phone-safe today and must stay so after the tightening.
  STILL_PHONE_SAFE = [
    "README.md",
    "docs/BPRM_PARITY_PLAN.md",
    "docs/BPRM_REG_SCHED_TWIN.md",
    "docs/demo_patient_chart_runbook.md"
  ].freeze

  test "the tracked prose paths that were phone-safe still are" do
    tracked, = Open3.capture2("git", "ls-files", chdir: ROOT)
    tracked = tracked.lines.map(&:chomp)
    present = STILL_PHONE_SAFE & tracked
    assert_operator present.size, :>=, 3, "the expected tracked safe paths are gone; update STILL_PHONE_SAFE"
    present.each do |path|
      assert_equal "phone-safe", classify(path).first, "#{path} should still be phone-safe"
    end
  end

  test "the matched rule's reason is printed" do
    _, _, out = classify("Gemfile.lock")
    assert_match(/<- .*dependenc/i, out)
  end

  test "one laptop-only path makes a mixed PR laptop-only and only it is listed" do
    tier, status, out = classify([ "README.md", "app/models/lakeraven/ehr/consent.rb", "docs/BPRM_PARITY_PLAN.md" ])
    assert_equal "laptop-only", tier
    assert_equal 0, status
    assert_includes out, "app/models/lakeraven/ehr/consent.rb"
    refute_includes out, "README.md"
  end

  test "case differences do not hide a laptop-only path" do
    [ "APP/SERVICES/LAKERAVEN/EHR/AUTHENTICATION_SERVICE.RB", ".GitHub/Workflows/CI.yml", "gemfile.LOCK" ].each do |path|
      tier, = classify(path)
      assert_equal "laptop-only", tier, path
    end
  end

  test "both sides of a rename count: the old path is laptop-only, the new one is not" do
    tier, = classify([ "app/services/lakeraven/ehr/authentication_service.rb", "app/services/lakeraven/ehr/widget_builder.rb" ])
    assert_equal "laptop-only", tier
  end

  test "an empty list is undetermined: laptop-only, exit 2" do
    # "\n\n   \n" used to be listed here. A line of spaces is a file name, not nothing, so it is
    # classified (see "a list holding only a whitespace-only name") and no longer counts as empty.
    [ "", "\n", "\n\n\n" ].each do |stdin|
      out, _err, status = run_script(stdin: stdin)
      assert_equal "laptop-only", out.lines.first.to_s.strip, stdin.inspect
      assert_equal 2, status.exitstatus, stdin.inspect
    end
  end

  test "a path that climbs out of the repo is undetermined: laptop-only, exit 2" do
    [ "app/../.github/workflows/ci.yml", "../README.md", "docs/../../etc/passwd" ].each do |path|
      tier, status, = classify([ "README.md", path ])
      assert_equal "laptop-only", tier, path
      assert_equal 2, status, path
    end
  end

  test "an unknown option is a usage error: laptop-only, exit 2" do
    out, _err, status = run_script("--bogus")
    assert_equal "laptop-only", out.lines.first.to_s.strip
    assert_equal 2, status.exitstatus
  end

  test "a missing rules file is undetermined, never phone-safe" do
    out, _err, status = run_script("--rules", "/nonexistent/risk-tiers.txt", stdin: "README.md\n")
    assert_equal "laptop-only", out.lines.first.to_s.strip
    assert_equal 2, status.exitstatus
  end

  test "an empty rules file is undetermined, never phone-safe" do
    Dir.mktmpdir do |dir|
      empty = File.join(dir, "rules.txt")
      File.write(empty, "# nothing here\n\n")
      out, _err, status = run_script("--rules", empty, stdin: "README.md\n")
      assert_equal "laptop-only", out.lines.first.to_s.strip
      assert_equal 2, status.exitstatus
    end
  end

  # ---- git mode --------------------------------------------------------------

  def in_scratch_repo
    Dir.mktmpdir do |dir|
      git = ->(*a) { out, err, st = Open3.capture3("git", "-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false", *a, chdir: dir); raise "git #{a.join(' ')}: #{err}" unless st.success?; out }
      git.call("init", "-q", "-b", "main")
      yield dir, git
    end
  end

  def commit_all(git, msg)
    git.call("add", "-A")
    git.call("commit", "-q", "-m", msg)
  end

  test "git mode: renaming a laptop-only file to a harmless name is still laptop-only" do
    in_scratch_repo do |dir, git|
      FileUtils.mkdir_p(File.join(dir, "app/services"))
      File.write(File.join(dir, "app/services/authentication_service.rb"), "# a\n" * 20)
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      git.call("checkout", "-q", "-b", "topic")
      git.call("mv", "app/services/authentication_service.rb", "app/services/widget_builder.rb")
      commit_all(git, "rename")
      out, _err, status = run_script("--base", "main", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip, out
      assert_equal 0, status.exitstatus
      assert_includes out, "app/services/authentication_service.rb"
    end
  end

  test "git mode: deleting a laptop-only file is laptop-only" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "Gemfile.lock"), "x\n")
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      git.call("checkout", "-q", "-b", "topic")
      git.call("rm", "-q", "Gemfile.lock")
      commit_all(git, "delete")
      out, = run_script("--base", "main", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip
    end
  end

  test "git mode: a docs-only change with a space in the name is phone-safe" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      git.call("checkout", "-q", "-b", "topic")
      FileUtils.mkdir_p(File.join(dir, "docs"))
      File.write(File.join(dir, "docs/my notes.md"), "y\n")
      commit_all(git, "docs")
      out, _err, status = run_script("--base", "main", chdir: dir)
      assert_equal "phone-safe", out.lines.first.strip, out
      assert_equal 0, status.exitstatus
    end
  end

  test "git mode: a file name containing a newline is laptop-only" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      git.call("checkout", "-q", "-b", "topic")
      FileUtils.mkdir_p(File.join(dir, "docs"))
      File.write(File.join(dir, "docs/a\nREADME.md"), "y\n")
      commit_all(git, "docs")
      out, _err, status = run_script("--base", "main", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip, out
      assert_equal 0, status.exitstatus
    end
  end

  test "git mode: no difference from the base is undetermined, not phone-safe" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      git.call("checkout", "-q", "-b", "topic")
      out, _err, status = run_script("--base", "main", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip
      assert_equal 2, status.exitstatus
    end
  end

  test "git mode: an unknown base is undetermined, not phone-safe" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      out, _err, status = run_script("--base", "no-such-ref", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip
      assert_equal 2, status.exitstatus
    end
  end

  # ---- locale YAML runs code when it loads (Copilot round 3) ------------------------------
  #
  # I18n's YAML backend loads with YAML.unsafe_load_file (i18n 1.15.2, Psych 5), so a locale
  # file can carry a Ruby object tag and run application code at load time. It is not display
  # text, so it is not phone-safe. Owner decision: locale YAML leaves the safe-list.
  LOCALE_YAML = [
    "config/locales/en.yml",
    "config/locales/es.yml",
    "config/locales/devise.en.yml",
    "config/locales/EN.YML"
  ].freeze

  LOCALE_YAML.each_with_index do |path, i|
    test "locale YAML is not on the safe-list ##{i}: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier, out
      assert_equal 0, status
      assert_match(/not on the safe-list/, out)
    end
  end

  test "a prose change with a locale file in it is laptop-only" do
    tier, status, out = classify([ "README.md", "docs/a.md", "config/locales/en.yml" ])
    assert_equal "laptop-only", tier, out
    assert_equal 0, status
  end

  test "the rules file no longer lists locale YAML as safe" do
    safe_section = File.read(RULES)[/^\[safe\]\s*$.*?(?=^\[|\z)/m].to_s
    refute_match(%r{locales}, safe_section.lines.reject { |l| l.strip.start_with?("#") }.join)
  end

  # ---- stylesheets are not display-only (panel round on #633) ------------------------------
  #
  # application.css does `require_tree .`, so any new file in the engine stylesheet directory is
  # served on every page, including sign-in, the cross-patient guard form and the screening
  # pages. The layout also emits the CSRF meta tag, and the repo ships no Content-Security-Policy.
  # A stylesheet can `@import` a remote sheet, leak a token with attribute selectors and `url()`,
  # or hide the self-harm safety prompt. It is not phone-safe. Owner decision: CSS leaves the
  # safe-list.
  STYLESHEETS = [
    "app/assets/stylesheets/lakeraven/ehr/application.css",
    "app/assets/stylesheets/lakeraven/ehr/new_theme.css",
    "app/assets/stylesheets/lakeraven/ehr/APP.CSS"
  ].freeze

  STYLESHEETS.each_with_index do |path, i|
    test "a stylesheet is not on the safe-list ##{i}: #{path}" do
      tier, status, out = classify(path)
      assert_equal "laptop-only", tier, out
      assert_equal 0, status
      assert_match(/not on the safe-list/, out)
    end
  end

  test "a prose change with a stylesheet in it is laptop-only" do
    tier, status, out = classify([ "README.md", "docs/a.md", "app/assets/stylesheets/lakeraven/ehr/application.css" ])
    assert_equal "laptop-only", tier, out
    assert_equal 0, status
  end

  test "the rules file no longer lists stylesheets as safe" do
    safe_section = File.read(RULES)[/^\[safe\]\s*$.*?(?=^\[|\z)/m].to_s
    refute_match(/stylesheets|\.css/, safe_section.lines.reject { |l| l.strip.start_with?("#") }.join)
  end

  test "the rules file says why stylesheets are laptop-only" do
    comments = File.read(RULES).lines.select { |l| l.strip.start_with?("#") }.join
    assert_match(/stylesheet/i, comments)
    assert_match(/require_tree|CSRF|exfiltrat|@import/i, comments)
  end

  # The macOS /bin/sh is bash 3.2, where a NUL ends the line: `docs/x.md\0app/x.rb` reads as
  # `docs/x.md` only. The workflow's jq check rejects control characters before the classifier
  # runs and CI runs bash 5, so CI is not exposed; the limit is documented where a person
  # who pipes paths in by hand will read it.
  test "the script header documents the bash 3.2 NUL limit" do
    header = File.read(File.join(ROOT, "bin", "risk-tier")).lines.first(70).join
    assert_match(/NUL/, header)
    assert_match(/3\.2/, header)
  end

  # ---- an explicit --base must name a ref (Copilot round 3) --------------------------------
  #
  # `--base ""` used to be treated as "no --base given", so the script fell through to reading
  # stdin and classified paths nobody had diffed. An explicit but empty ref is an error.
  test "an empty --base is undetermined even when paths arrive on stdin" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      out, _err, status = run_script("--base", "", stdin: "README.md\n", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip, out
      assert_equal 2, status.exitstatus
      assert_match(/--base/, out)
    end
  end

  test "an empty --base with nothing on stdin is also undetermined" do
    in_scratch_repo do |dir, git|
      File.write(File.join(dir, "README.md"), "x\n")
      commit_all(git, "base")
      out, _err, status = run_script("--base", "", chdir: dir)
      assert_equal "laptop-only", out.lines.first.strip, out
      assert_equal 2, status.exitstatus
    end
  end

  # ---- the rules file --------------------------------------------------------

  # Rule lines, with comments, blanks and the `[section]` headers removed.
  def rule_lines
    File.readlines(RULES, chomp: true).reject { |l| l.strip.empty? || l.start_with?("#") || l.strip.match?(/\A\[\w+\]\z/) }
  end

  def section_rule_lines(name)
    inside = false
    File.readlines(RULES, chomp: true).each_with_object([]) do |l, acc|
      next if l.strip.empty? || l.start_with?("#")
      if (m = l.strip.match(/\A\[(\w+)\]\z/))
        inside = (m[1] == name)
        next
      end
      acc << l if inside
    end
  end

  test "the rules file has a [safe] section, after the laptop-only rules" do
    headers = File.readlines(RULES, chomp: true).map(&:strip).grep(/\A\[\w+\]\z/)
    assert_equal [ "[safe]" ], headers
    refute_empty section_rule_lines("safe")
    assert_operator rule_lines.size, :>, section_rule_lines("safe").size, "the laptop-only rules must still exist"
  end

  test "the safe-list is narrow: nothing that holds code, tests, features, db, config, bin or CI" do
    section_rule_lines("safe").each do |l|
      glob = l.split(/\s+#\s+/, 2).first.strip
      refute_match(%r{\A(\*|app/(controllers|services|models|gateways|policies|jobs|lib|repositories|rulesets|decorators|terminology)|lib/|test|features|db|bin|\.github|Gemfile)}i, glob, "safe glob too broad: #{glob}")
      refute_match(%r{\A(config/\*|config/measures|config/routes|config/initializers)}i, glob, "safe glob too broad: #{glob}")
    end
  end

  test "every rule carries a reason" do
    rules = rule_lines
    refute_empty rules
    rules.each { |l| assert_match(/\S\s+#\s+\S/, l, "rule without a reason: #{l.inspect}") }
  end

  test "every non-forward rule matches at least one tracked file today" do
    tracked, = Open3.capture2("git", "ls-files", chdir: ROOT)
    out, err, status = run_script("--coverage", stdin: tracked)
    assert status.success?, err
    rules = rule_lines
    forward = rules.select { |l| l.include?("[forward]") }.map { |l| l.split(/\s+#\s+/, 2).first.strip }
    unmatched = out.lines.map { |l| l.chomp.split("\t", 2) }.select { |n, _| n.to_i.zero? }.map(&:last)
    assert_empty unmatched - forward, "rules matching no tracked file and not marked [forward]"
  end

  # ---- the audit: a second list, independent of the rules ----------------------
  #
  # The rules file is a blocklist written by someone who knew which surfaces mattered, so it
  # can only be as good as that person's memory. Gate round 1 on #633 found a dozen sensitive
  # files (authorization tests, disclosure, export, breach, amendment) that no rule matched.
  # This audit is a net under it: any tracked file whose path contains one of these words must
  # be laptop-only, whatever the rules say. A new file with such a name that no rule covers
  # fails here, so the gap is found by CI and not by a reader.
  #
  # Under the safe-list this is the second net, under the safe globs: a docs or view file
  # whose name contains one of these words stays laptop-only because a rule wins over a glob.
  #
  # Measured over `git ls-files` when this was written: "sign" is rejected because half of its
  # four hits are features/onc/vital_signs_* (clinical vitals, not signatures); the signature
  # files are caught by "signat". "key" is not added: of its three hits two are already oauth
  # migrations and one is a program-key test with nothing to do with credentials. Keywords with
  # no hits today (tenant, credential, secret, permission, privilege, segment, password, cipher)
  # stay: they cost nothing and catch the file that does not exist yet.
  AUDIT_KEYWORDS = %w[
    auth token consent disclos export egress audit part2 tenant credential secret jwks oauth
    smart scope permission privilege segment breach incident amend csrf throttle rate_limit
    ehi session password login encrypt cipher signat
  ].freeze
  AUDIT_DIRS = %w[app lib config db test features docs].freeze

  test "every tracked path containing a sensitive word is laptop-only, whatever the rules say" do
    tracked, err, status = Open3.capture3("git", "ls-files", *AUDIT_DIRS, chdir: ROOT)
    assert status.success?, err
    candidates = tracked.lines.map(&:chomp).select { |p| AUDIT_KEYWORDS.any? { |k| p.downcase.include?(k) } }
    assert_operator candidates.size, :>, 50, "the audit found almost nothing; is git ls-files empty?"
    uncovered = candidates.reject { |p| classify(p).first == "laptop-only" }
    assert_empty uncovered, "sensitive-sounding paths that classify phone-safe; add a rule for each"
  end

  # ---- the whole tree against the safe-list -------------------------------------------------
  #
  # An independent statement of what MAY be phone-safe. Every tracked file outside it must be
  # laptop-only, so a controller, service, serializer, test, feature or migration with any name
  # at all cannot slip through, which is the hole the blocklist had.
  SAFE_PATH_PATTERNS = [
    %r{\A(README|CHANGELOG)\.md\z}i,
    %r{\Adocs/[^/]+\.md\z}i,
    %r{\Aapp/assets/images/[^/]+\.(png|jpe?g|gif|ico)\z}i
  ].freeze

  def laptop_paths_in(tracked_paths)
    out, err, status = run_script(stdin: tracked_paths.join("\n") + "\n")
    assert status.success?, err
    out.lines.drop(1).map { |l| l.chomp.sub(/\A  /, "").split("  <- ", 2).first }
  end

  test "every tracked path outside the safe patterns is laptop-only" do
    tracked, err, status = Open3.capture3("git", "ls-files", chdir: ROOT)
    assert status.success?, err
    paths = tracked.lines.map(&:chomp)
    assert_operator paths.size, :>, 500, "git ls-files returned almost nothing"
    outside = paths.reject { |p| SAFE_PATH_PATTERNS.any? { |re| re.match?(p) } }
    assert_operator outside.size, :>, 400
    listed = laptop_paths_in(paths)
    leaked = outside - listed
    assert_empty leaked, "tracked paths outside the safe patterns that the classifier would call phone-safe"
  end

  test "controllers, services, serializers, models, tests, features, db and config are never phone-safe, by name" do
    tracked, = Open3.capture2("git", "ls-files", chdir: ROOT)
    paths = tracked.lines.map(&:chomp).select do |p|
      p.start_with?("app/controllers/", "app/services/", "app/models/", "app/gateways/", "app/policies/", "app/jobs/", "app/lib/", "test/", "features/", "db/", "lib/", "bin/", ".github/") ||
        p.start_with?("config/")
    end
    assert_operator paths.size, :>, 300
    assert_empty paths - laptop_paths_in(paths)
  end

  test "the safe patterns are really used: safe tracked files exist and are phone-safe when they match no rule" do
    tracked, = Open3.capture2("git", "ls-files", "README.md", "docs", "app/assets", chdir: ROOT)
    safe = tracked.lines.map(&:chomp).select { |p| SAFE_PATH_PATTERNS.any? { |re| re.match?(p) } }
    assert_operator safe.size, :>=, 4 # the engine stylesheet was the fifth until CSS left the safe-list
    ok = safe.select { |p| classify(p).first == "phone-safe" }
    assert_operator ok.size, :>, 3, "the safe-list admits almost nothing; is it empty?"
  end

  test "no tracked view or helper is ever phone-safe: ERB and helpers run Ruby and render patient data" do
    tracked, err, status = Open3.capture3("git", "ls-files", "app/views", "app/helpers", chdir: ROOT)
    assert status.success?, err
    paths = tracked.lines.map(&:chomp)
    assert_operator paths.size, :>, 5, "no tracked views or helpers; is git ls-files empty?"
    assert_empty paths - laptop_paths_in(paths), "views or helpers the classifier would call phone-safe"
    assert paths.any? { |p| p.end_with?(".erb") }, "expected at least one tracked .erb"
  end

  test "the safe-list rules file names neither app/views nor app/helpers" do
    safe = File.read(RULES).split(/^\[safe\]\s*$/, 2).last.to_s
    refute_match(%r{^\s*app/(views|helpers)}, safe)
  end

  test "the audit does not sweep in vital signs" do
    refute AUDIT_KEYWORDS.any? { |k| "features/onc/vital_signs_compliance.feature".include?(k) }
  end
end
