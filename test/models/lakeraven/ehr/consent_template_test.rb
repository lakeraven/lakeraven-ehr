# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ConsentTemplateTest < ActiveSupport::TestCase
      KEYS = %w[bh-treatment telehealth release-of-information].freeze

      setup do
        ConsentTemplate.delete_all if defined?(ConsentTemplate) && ConsentTemplate.table_exists?
      end

      test "install_defaults! creates version 1 of all three templates with synthetic wording" do
        ConsentTemplate.install_defaults!

        assert_equal 3, ConsentTemplate.count
        KEYS.each do |key|
          row = ConsentTemplate.find_by!(key: key, version: 1)
          assert row.title.present?
          assert row.body.present?
          assert_match(/SYNTHETIC|synthetic|placeholder/i, row.body)
          assert_includes Consent::SCOPES.keys, row.consent_scope
        end
      end

      test "install_defaults! is idempotent" do
        ConsentTemplate.install_defaults!
        ConsentTemplate.install_defaults!

        assert_equal 3, ConsentTemplate.count
        KEYS.each do |key|
          assert_equal 1, ConsentTemplate.where(key: key).count
        end
      end

      test "current returns the highest version for a key" do
        ConsentTemplate.install_defaults!
        original = ConsentTemplate.find_by!(key: "bh-treatment", version: 1)
        ConsentTemplate.create!(
          key: "bh-treatment",
          version: 2,
          title: "SYNTHETIC BH v2",
          body: "SYNTHETIC placeholder body version two.",
          consent_scope: original.consent_scope
        )

        current = ConsentTemplate.current("bh-treatment")
        assert_equal 2, current.version
        assert_equal "SYNTHETIC BH v2", current.title
      end

      test "current returns nil for an unknown key" do
        ConsentTemplate.install_defaults!
        assert_nil ConsentTemplate.current("unknown-template-key")
      end

      test "key and version are unique together" do
        ConsentTemplate.install_defaults!
        original = ConsentTemplate.find_by!(key: "telehealth", version: 1)

        duplicate = ConsentTemplate.new(
          key: original.key,
          version: original.version,
          title: "dup",
          body: "dup",
          consent_scope: original.consent_scope
        )
        refute duplicate.valid?
        assert duplicate.errors[:version].any? || duplicate.errors[:key].any?
      end

      test "a saved template row is immutable" do
        ConsentTemplate.install_defaults!
        row = ConsentTemplate.find_by!(key: "release-of-information", version: 1)

        assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(title: "changed") }
        assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }

        row.reload
        refute_equal "changed", row.title
      end

      test "increment! and decrement! on a persisted template raise ReadOnlyRecord" do
        ConsentTemplate.install_defaults!
        row = ConsentTemplate.find_by!(key: "bh-treatment", version: 1)
        version_before = row.version

        assert_raises(ActiveRecord::ReadOnlyRecord) { row.increment!(:version) }
        assert_raises(ActiveRecord::ReadOnlyRecord) { row.decrement!(:version) }

        row.reload
        assert_equal version_before, row.version
      end
    end
  end
end
