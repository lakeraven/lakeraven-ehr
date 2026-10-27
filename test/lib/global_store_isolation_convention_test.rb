# frozen_string_literal: true

require "test_helper"

# Every process-global in-memory store with a class-level reset hook must be
# cleared via GlobalStoreIsolation::STORE_RESETS (see test/support/global_store_isolation.rb).
class GlobalStoreIsolationConventionTest < ActiveSupport::TestCase
  # Classes that define reset! / reset_instance! / reset_store! but are not
  # suite-wide process globals — each entry must stay commented with a reason.
  EXEMPTED_RESETTERS = {
    "Lakeraven::EHR::BehavioralHealthProgramConfiguration" =>
      "Database-backed ActiveRecord rows; reset! clears the test table, not in-process memory"
  }.freeze

  CLASS_LEVEL_SELF_RESET = /def\s+self\.reset(?:!|_instance!|_store!)(?:\s|$|=)/
  EIGENCLASS_RESET = /class\s+<<\s+self[\s\S]*?^\s*def\s+reset(?:!|_instance!|_store!)(?:\s|$|=)/m

  def test_every_class_level_store_reset_is_registered_in_global_store_isolation
    store_resets_source = File.read(engine_root.join("test/support/global_store_isolation.rb"))
    missing = []

    resetter_constants.each do |constant_name|
      next if EXEMPTED_RESETTERS.key?(constant_name)
      next if store_resets_source.include?(constant_name)

      next if reset_cleared_by_global_store_isolation?(constant_name)

      missing << constant_name
    end

    assert_empty missing,
                 "Add each class to GlobalStoreIsolation::STORE_RESETS or EXEMPTED_RESETTERS " \
                 "(with a reason): #{missing.join(', ')}"
  end

  private

  def resetter_constants
    app_lib_rb_files.flat_map { |path| constants_with_class_level_reset_in(path) }.uniq.sort
  end

  def app_lib_rb_files
    %w[app lib].flat_map { |root| Dir[engine_root.join(root, "**", "*.rb")] }
  end

  def engine_root
    Lakeraven::EHR::Engine.root
  end

  def constants_with_class_level_reset_in(path)
    source = File.read(path)
    return [] unless source.match?(CLASS_LEVEL_SELF_RESET) || source.match?(EIGENCLASS_RESET)

    [ constant_name_for_path(path) ]
  end

  def constant_name_for_path(absolute_path)
    rel = Pathname.new(absolute_path).relative_path_from(engine_root).to_s
    rel = rel.delete_prefix("app/").delete_prefix("lib/")
    rel = rel.sub(%r{\A(?:controllers|models|services|mailers|jobs|helpers|channels|lib)/}, "")
    rel.sub(/\.rb\z/, "").camelize
  end

  def reset_cleared_by_global_store_isolation?(constant_name)
    case constant_name
    when "Lakeraven::EHR::AssertionReplayGuard"
      assert_replay_guard_cleared_by_global_reset!
    when "Lakeraven::EHR::LoginThrottle"
      assert_login_throttle_cleared_by_global_reset!
    when "Lakeraven::EHR::ProvenanceStore"
      assert_provenance_store_cleared_by_global_reset!
    when "Lakeraven::EHR::ExportsController"
      assert_exports_store_cleared_by_global_reset!
    else
      false
    end
  end

  def assert_replay_guard_cleared_by_global_reset!
    guard = Lakeraven::EHR::AssertionReplayGuard
    guard.reset!
    client_id = "convention-synthetic-client"
    jti = "convention-synthetic-jti-#{SecureRandom.hex(4)}"
    exp = 5.minutes.from_now.to_i

    refute guard.replayed?(client_id, jti, exp),
           "first use of jti should be accepted"
    assert guard.replayed?(client_id, jti, exp),
           "second use of the same jti should be refused"
    GlobalStoreIsolation.reset!
    !guard.replayed?(client_id, jti, exp)
  ensure
    guard.reset!
  end

  def assert_login_throttle_cleared_by_global_reset!
    key = "convention-throttle-#{SecureRandom.hex(4)}"
    Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS.times do
      Lakeraven::EHR::LoginThrottle.record_failure(key)
    end
    assert Lakeraven::EHR::LoginThrottle.throttled?(key)
    GlobalStoreIsolation.reset!
    !Lakeraven::EHR::LoginThrottle.throttled?(key)
  end

  def assert_provenance_store_cleared_by_global_reset!
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "convention-synthetic", activity: "CREATE",
        agent_who_id: "synthetic-agent", agent_who_type: "Practitioner", recorded: Time.current
      )
    )
    assert_operator Lakeraven::EHR::ProvenanceStore.instance.count, :>, 0
    GlobalStoreIsolation.reset!
    Lakeraven::EHR::ProvenanceStore.instance.count.zero?
  end

  def assert_exports_store_cleared_by_global_reset!
    export_id = "convention-export-#{SecureRandom.hex(4)}"
    Lakeraven::EHR::ExportsController.store[export_id] = Lakeraven::EHR::BulkExport.new(
      id: export_id, export_type: "patient", status: "pending",
      request_url: "https://example.test/exports",
      output_format: "application/fhir+ndjson", client_id: "synthetic-client"
    )
    assert Lakeraven::EHR::ExportsController.store.key?(export_id)
    GlobalStoreIsolation.reset!
    Lakeraven::EHR::ExportsController.store.empty?
  end
end
