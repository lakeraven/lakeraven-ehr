# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DisclosureTest < ActiveSupport::TestCase
      # =============================================================================
      # CREATION
      # =============================================================================

      test "creates a valid disclosure" do
        d = create_disclosure
        assert d.persisted?
      end

      # =============================================================================
      # VALIDATIONS
      # =============================================================================

      test "requires patient_dfn" do
        d = Disclosure.new(recipient_name: "Lab Corp", purpose: "treatment",
                            data_disclosed: "Lab results", disclosed_by: "301")
        refute d.valid?
        assert d.errors[:patient_dfn].any?
      end

      test "requires recipient_name" do
        d = Disclosure.new(patient_dfn: "1", purpose: "treatment",
                            data_disclosed: "Lab results", disclosed_by: "301")
        refute d.valid?
        assert d.errors[:recipient_name].any?
      end

      test "requires purpose" do
        d = Disclosure.new(patient_dfn: "1", recipient_name: "Lab Corp",
                            data_disclosed: "Lab results", disclosed_by: "301")
        refute d.valid?
        assert d.errors[:purpose].any?
      end

      test "requires data_disclosed" do
        d = Disclosure.new(patient_dfn: "1", recipient_name: "Lab Corp",
                            purpose: "treatment", disclosed_by: "301")
        refute d.valid?
        assert d.errors[:data_disclosed].any?
      end

      test "requires disclosed_by" do
        d = Disclosure.new(patient_dfn: "1", recipient_name: "Lab Corp",
                            purpose: "treatment", data_disclosed: "Lab results")
        refute d.valid?
        assert d.errors[:disclosed_by].any?
      end

      # =============================================================================
      # IMMUTABILITY
      # =============================================================================

      test "cannot be updated after creation" do
        d = create_disclosure
        assert_raises(ActiveRecord::ReadOnlyRecord) do
          d.update!(recipient_name: "New Name")
        end
      end

      test "cannot be destroyed" do
        d = create_disclosure
        assert_raises(ActiveRecord::ReadOnlyRecord) do
          d.destroy!
        end
      end

      # =============================================================================
      # SCOPES
      # =============================================================================

      test "for_patient scope filters by patient_dfn" do
        create_disclosure(patient_dfn: "1")
        create_disclosure(patient_dfn: "2")

        assert_equal 1, Disclosure.for_patient("1").count
      end

      test "within_retention excludes disclosures older than 6 years" do
        create_disclosure(disclosed_at: 5.years.ago)
        create_disclosure(disclosed_at: 7.years.ago)

        assert_equal 1, Disclosure.within_retention.count
      end

      test "accounting_for_patient returns reverse chronological within 6 years" do
        old = create_disclosure(disclosed_at: 2.years.ago)
        recent = create_disclosure(disclosed_at: 1.month.ago)
        create_disclosure(patient_dfn: "999", disclosed_at: 1.day.ago)

        result = Disclosure.accounting_for_patient("1")

        assert_equal 2, result.count
        assert_equal recent.id, result.first.id
      end

      private

      def create_disclosure(attrs = {})
        defaults = {
          patient_dfn: "1", recipient_name: "Lab Corp", purpose: "treatment",
          data_disclosed: "Lab results", disclosed_by: "301",
          disclosed_at: Time.current
        }
        Disclosure.create!(defaults.merge(attrs))
      end
    end
  end
end
