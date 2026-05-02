# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EmergencyAccessTest < ActiveSupport::TestCase
      VALID_ATTRS = {
        patient_dfn: "1", accessed_by: "301", reason: "medical_emergency",
        justification: "Patient unresponsive, need immediate access to medication history",
        accessed_at: Time.current, expires_at: 4.hours.from_now
      }.freeze

      test "creates a valid emergency access" do
        ea = EmergencyAccess.create!(VALID_ATTRS)
        assert ea.persisted?
      end

      test "requires patient_dfn" do
        ea = EmergencyAccess.new(VALID_ATTRS.except(:patient_dfn))
        refute ea.valid?
        assert ea.errors[:patient_dfn].any?
      end

      test "requires accessed_by" do
        ea = EmergencyAccess.new(VALID_ATTRS.except(:accessed_by))
        refute ea.valid?
      end

      test "requires reason" do
        ea = EmergencyAccess.new(VALID_ATTRS.except(:reason))
        refute ea.valid?
      end

      test "validates reason is a recognized emergency type" do
        ea = EmergencyAccess.new(VALID_ATTRS.merge(reason: "curiosity"))
        refute ea.valid?
      end

      test "requires justification" do
        ea = EmergencyAccess.new(VALID_ATTRS.except(:justification))
        refute ea.valid?
      end

      test "requires accessed_at" do
        ea = EmergencyAccess.new(VALID_ATTRS.except(:accessed_at))
        refute ea.valid?
      end

      test "requires expires_at" do
        ea = EmergencyAccess.new(VALID_ATTRS.except(:expires_at))
        refute ea.valid?
      end

      test "accepts all defined emergency reasons" do
        EmergencyAccess::VALID_REASONS.each do |reason|
          ea = EmergencyAccess.new(VALID_ATTRS.merge(reason: reason))
          assert ea.valid?, "Expected #{reason} to be valid"
        end
      end

      test "cannot be updated after creation" do
        ea = EmergencyAccess.create!(VALID_ATTRS)
        assert_raises(ActiveRecord::ReadOnlyRecord) { ea.update!(justification: "Changed") }
      end

      test "active? returns true when not expired" do
        ea = EmergencyAccess.create!(VALID_ATTRS.merge(expires_at: 2.hours.from_now))
        assert ea.active?
      end

      test "active? returns false when expired" do
        ea = EmergencyAccess.create!(VALID_ATTRS.merge(expires_at: 1.hour.ago))
        refute ea.active?
      end

      test "reviewed? returns false when not reviewed" do
        ea = EmergencyAccess.create!(VALID_ATTRS)
        refute ea.reviewed?
      end

      test "for_patient scope filters by patient_dfn" do
        EmergencyAccess.create!(VALID_ATTRS)
        EmergencyAccess.create!(VALID_ATTRS.merge(patient_dfn: "999"))

        assert_equal 1, EmergencyAccess.for_patient("1").count
      end

      test "pending_review scope returns unreviewed" do
        EmergencyAccess.create!(VALID_ATTRS)
        assert_equal 1, EmergencyAccess.pending_review.count
      end

      test "active scope returns unexpired" do
        EmergencyAccess.create!(VALID_ATTRS.merge(expires_at: 2.hours.from_now))
        EmergencyAccess.create!(VALID_ATTRS.merge(expires_at: 1.hour.ago))

        assert_equal 1, EmergencyAccess.active.count
      end
    end
  end
end
