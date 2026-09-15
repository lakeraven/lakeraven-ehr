# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Break-the-glass is the access most worth recording and the one most
    # likely to be defended afterwards. ONC §170.315(d)(5) wants the path to
    # exist; §164.312(b) wants it to leave a trail of its own, in the same log
    # a reviewer is already reading — not in a table only this feature knows
    # about.
    class EmergencyAccessAuditTest < ActiveSupport::TestCase
      setup { AuditEvent.delete_all }

      def grant!(**overrides)
        EmergencyAccess.create!({
          patient_dfn: "1", accessed_by: "301", accessed_by_name: "PROVIDER,TEST",
          reason: "medical_emergency", justification: "Unresponsive patient, no chart access",
          accessed_at: Time.current, expires_at: 4.hours.from_now
        }.merge(overrides))
      end

      test "breaking the glass writes to the PHI access log" do
        assert_difference -> { AuditEvent.count }, 1 do
          grant!
        end

        event = AuditEvent.order(:id).last
        assert_equal "security", event.event_type
        assert_equal "E", event.action
        assert_equal "Patient", event.entity_type
        assert_equal "1", event.entity_identifier
        assert_equal "301", event.agent_who_identifier
        assert_match(/emergency/i, event.outcome_desc.to_s)
      end

      # The justification is free text a clinician typed under pressure. It
      # belongs in the emergency-access record; it does not belong in a log
      # built to hold no PHI (ADR 0002).
      test "the audit row records the reason code, never the free-text justification" do
        grant!(justification: "Patient SYNTHETIC,NAME collapsed in the lobby")

        event = AuditEvent.order(:id).last
        refute_includes event.attributes.values.compact.map(&:to_s).join(" "), "SYNTHETIC,NAME"
      end

      # If the glass cannot be broken audibly, it is not broken: the grant and
      # its audit row commit together or not at all.
      test "an emergency access whose audit cannot be written is not granted" do
        before = EmergencyAccess.count

        AuditEvent.define_singleton_method(:create!) do |*|
          raise ActiveRecord::StatementInvalid, "audit store unavailable"
        end

        assert_raises(ActiveRecord::StatementInvalid) { grant! }
        assert_equal before, EmergencyAccess.count,
          "the glass was broken with no record that it had been"
      ensure
        AuditEvent.singleton_class.send(:remove_method, :create!)
      end
    end
  end
end
