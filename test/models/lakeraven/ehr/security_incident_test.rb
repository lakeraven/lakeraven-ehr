# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SecurityIncidentTest < ActiveSupport::TestCase
      # ======================================================================
      # VALIDATIONS
      # ======================================================================

      test "valid incident with required attributes" do
        incident = SecurityIncident.new(
          severity: "high",
          incident_type: "brute_force",
          status: "open",
          description: "Multiple failed logins from 10.0.0.1",
          ip_address: "10.0.0.1",
          dedup_key: "brute_force:10.0.0.1:1234567890"
        )
        assert incident.valid?
      end

      test "requires severity" do
        incident = SecurityIncident.new(severity: nil, incident_type: "brute_force",
          status: "open", description: "test", dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:severity], "can't be blank"
      end

      test "requires incident_type" do
        incident = SecurityIncident.new(severity: "high", incident_type: nil,
          status: "open", description: "test", dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:incident_type], "can't be blank"
      end

      test "requires status" do
        incident = SecurityIncident.new(severity: "high", incident_type: "brute_force",
          status: nil, description: "test", dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:status], "can't be blank"
      end

      test "requires description" do
        incident = SecurityIncident.new(severity: "high", incident_type: "brute_force",
          status: "open", description: nil, dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:description], "can't be blank"
      end

      test "requires dedup_key" do
        incident = SecurityIncident.new(severity: "high", incident_type: "brute_force",
          status: "open", description: "test", dedup_key: nil)
        assert_not incident.valid?
        assert_includes incident.errors[:dedup_key], "can't be blank"
      end

      test "validates severity inclusion" do
        incident = SecurityIncident.new(severity: "extreme", incident_type: "brute_force",
          status: "open", description: "test", dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:severity], "is not included in the list"
      end

      test "validates status inclusion" do
        incident = SecurityIncident.new(severity: "high", incident_type: "brute_force",
          status: "banana", description: "test", dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:status], "is not included in the list"
      end

      test "validates incident_type inclusion" do
        incident = SecurityIncident.new(severity: "high", incident_type: "invalid",
          status: "open", description: "test", dedup_key: "k")
        assert_not incident.valid?
        assert_includes incident.errors[:incident_type], "is not included in the list"
      end

      # ======================================================================
      # STATUS TRANSITIONS
      # ======================================================================

      test "investigate! transitions from open to investigating" do
        incident = build_incident(status: "open")
        incident.investigate!
        assert_equal "investigating", incident.status
      end

      test "resolve! transitions from open to resolved" do
        incident = build_incident(status: "open")
        incident.resolve!
        assert_equal "resolved", incident.status
        assert_not_nil incident.resolved_at
      end

      test "resolve! transitions from investigating to resolved" do
        incident = build_incident(status: "investigating")
        incident.resolve!
        assert_equal "resolved", incident.status
        assert_not_nil incident.resolved_at
      end

      test "investigate! raises error from resolved status" do
        incident = build_incident(status: "resolved")
        assert_raises(SecurityIncident::InvalidTransitionError) do
          incident.investigate!
        end
      end

      test "resolve! raises error from resolved status" do
        incident = build_incident(status: "resolved")
        assert_raises(SecurityIncident::InvalidTransitionError) do
          incident.resolve!
        end
      end

      # ======================================================================
      # CONFIGURED THRESHOLD
      # ======================================================================

      test "configured_threshold returns env value when valid" do
        original = ENV["SECURITY_MONITOR_THRESHOLD"]
        ENV["SECURITY_MONITOR_THRESHOLD"] = "8"
        assert_equal 8, SecurityIncident.configured_threshold
      ensure
        ENV["SECURITY_MONITOR_THRESHOLD"] = original
      end

      test "configured_threshold returns default for non-numeric env" do
        original = ENV["SECURITY_MONITOR_THRESHOLD"]
        ENV["SECURITY_MONITOR_THRESHOLD"] = "banana"
        assert_equal SecurityIncident::DEFAULT_THRESHOLD, SecurityIncident.configured_threshold
      ensure
        ENV["SECURITY_MONITOR_THRESHOLD"] = original
      end

      test "configured_threshold returns default for zero" do
        original = ENV["SECURITY_MONITOR_THRESHOLD"]
        ENV["SECURITY_MONITOR_THRESHOLD"] = "0"
        assert_equal SecurityIncident::DEFAULT_THRESHOLD, SecurityIncident.configured_threshold
      ensure
        ENV["SECURITY_MONITOR_THRESHOLD"] = original
      end

      test "configured_threshold returns default when env not set" do
        original = ENV["SECURITY_MONITOR_THRESHOLD"]
        ENV.delete("SECURITY_MONITOR_THRESHOLD")
        assert_equal SecurityIncident::DEFAULT_THRESHOLD, SecurityIncident.configured_threshold
      ensure
        ENV["SECURITY_MONITOR_THRESHOLD"] = original
      end

      # ======================================================================
      # DEDUP KEY
      # ======================================================================

      test "generate_dedup_key creates deterministic key" do
        time = Time.zone.parse("2026-03-06 10:30:00")
        key = SecurityIncident.generate_dedup_key("brute_force", "10.0.0.1", time)
        expected_bucket = time.beginning_of_hour.to_i
        assert_equal "brute_force:10.0.0.1:#{expected_bucket}", key
      end

      # ======================================================================
      # PREDICATES
      # ======================================================================

      test "open? for open status" do
        assert SecurityIncident.new(status: "open").open?
      end

      test "open? false for resolved" do
        refute SecurityIncident.new(status: "resolved").open?
      end

      test "resolved? for resolved status" do
        assert SecurityIncident.new(status: "resolved").resolved?
      end

      test "resolved? false for open" do
        refute SecurityIncident.new(status: "open").resolved?
      end

      private

      def build_incident(status: "open")
        SecurityIncident.new(
          severity: "high",
          incident_type: "brute_force",
          status: status,
          description: "test incident",
          ip_address: "10.0.0.#{rand(255)}",
          dedup_key: "test:#{SecureRandom.hex(4)}"
        )
      end
    end
  end
end
