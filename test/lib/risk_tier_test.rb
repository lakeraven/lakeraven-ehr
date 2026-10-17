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
# First line of output is "laptop-only" or "phone-safe". Every matched path follows as
# "  <path>  <- <rule>". A PR with ANY laptop-only path is laptop-only. An empty or
# undeterminable list is laptop-only with exit 2: absence of data is never verification.
# It labels; it does not gate, so a classified PR exits 0 either way.
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
    "docs/BPRM_PARITY_PLAN.md",
    "app/controllers/lakeraven/ehr/patients_controller.rb",
    "test/integration/patient_search_total_test.rb",
    "config/measures/bmi_screening.yml",
    "app/assets/stylesheets/lakeraven/ehr/application.css",
    "app/terminology/lakeraven/ehr/example_code_system.rb",
    "features/fhir/patient.feature",
    "docs/my notes.md",
    "features/onc/vital_signs_compliance.feature",
    "./README.md"
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
    [ "", "\n", "\n\n   \n" ].each do |stdin|
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
      File.write(File.join(dir, "my notes.md"), "y\n")
      commit_all(git, "docs")
      out, _err, status = run_script("--base", "main", chdir: dir)
      assert_equal "phone-safe", out.lines.first.strip, out
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

  # ---- the rules file --------------------------------------------------------

  test "every rule carries a reason" do
    rules = File.readlines(RULES, chomp: true).reject { |l| l.strip.empty? || l.start_with?("#") }
    refute_empty rules
    rules.each { |l| assert_match(/\S\s+#\s+\S/, l, "rule without a reason: #{l.inspect}") }
  end

  test "every non-forward rule matches at least one tracked file today" do
    tracked, = Open3.capture2("git", "ls-files", chdir: ROOT)
    out, err, status = run_script("--coverage", stdin: tracked)
    assert status.success?, err
    rules = File.readlines(RULES, chomp: true).reject { |l| l.strip.empty? || l.start_with?("#") }
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
  # A net, not a proof: a sensitive file with an unremarkable name passes straight through.
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

  test "the audit does not sweep in vital signs" do
    refute AUDIT_KEYWORDS.any? { |k| "features/onc/vital_signs_compliance.feature".include?(k) }
  end
end
