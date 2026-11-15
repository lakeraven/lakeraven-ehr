# frozen_string_literal: true

require "test_helper"

# Part2Label is the marker a record carries when it holds (or may hold)
# 42 CFR Part 2 content (#906). One row per (record_type, record_id).
# Synthetic identifiers throughout.
module Lakeraven
  module EHR
    class Part2LabelTest < ActiveSupport::TestCase
      VALID = {
        patient_dfn: "9001", record_type: "tiu_note", record_id: "70001",
        security_code: "42CFRPart2"
      }.freeze

      test "the table is lakeraven_ehr_part2_labels" do
        assert_equal "lakeraven_ehr_part2_labels", Part2Label.table_name
        assert Part2Label.table_exists?
      end

      test "the table has the label columns and timestamps" do
        columns = Part2Label.columns_hash
        %w[patient_dfn record_type record_id security_code].each do |name|
          assert columns.key?(name), "missing column #{name}"
          assert_equal :string, columns[name].type, "#{name} should be a string"
          refute columns[name].null, "#{name} should be NOT NULL"
        end
        assert columns.key?("created_at")
        assert columns.key?("updated_at")
      end

      test "the security code constant is the HL7 v3 ActCode for 42 CFR Part 2" do
        assert_equal "42CFRPart2", Part2Label::PART2_SECURITY_CODE
        assert_equal "http://terminology.hl7.org/CodeSystem/v3-ActCode", Part2Label::SECURITY_SYSTEM
      end

      test "a row with every field is valid and saves" do
        label = Part2Label.new(VALID)
        assert label.valid?, label.errors.full_messages.to_sentence
        assert label.save
      end

      %i[patient_dfn record_type record_id security_code].each do |field|
        test "a nil #{field} is invalid" do
          label = Part2Label.new(VALID.merge(field => nil))
          refute label.valid?
          assert label.errors[field].any?
        end

        test "a blank #{field} is invalid" do
          label = Part2Label.new(VALID.merge(field => "  "))
          refute label.valid?
          assert label.errors[field].any?
        end
      end

      # --- one row per (record_type, record_id) ---

      test "a second row for the same record is invalid" do
        Part2Label.create!(VALID)
        duplicate = Part2Label.new(VALID.merge(patient_dfn: "9002"))
        refute duplicate.valid?
      end

      test "the database refuses a second row for the same record" do
        Part2Label.create!(VALID)
        assert_raises(ActiveRecord::RecordNotUnique) do
          # Savepoint so the refused statement does not poison the test transaction.
          Part2Label.transaction(requires_new: true) do
            Part2Label.new(VALID).save!(validate: false)
          end
        end
        assert_equal 1, Part2Label.where(record_type: "tiu_note", record_id: "70001").count
      end

      test "the same record id under a different record type is a separate row" do
        Part2Label.create!(VALID)
        assert Part2Label.new(VALID.merge(record_type: "other_record")).valid?
      end

      test "a different record id under the same record type is a separate row" do
        Part2Label.create!(VALID)
        assert Part2Label.new(VALID.merge(record_id: "70002")).valid?
      end

      # --- mark! ---

      test "mark! creates the row with the Part 2 security code" do
        assert_difference -> { Part2Label.count }, 1 do
          Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")
        end

        row = Part2Label.find_by!(record_type: "tiu_note", record_id: "70001")
        assert_equal "9001", row.patient_dfn
        assert_equal "42CFRPart2", row.security_code
      end

      test "mark! twice for the same record is idempotent" do
        Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")

        assert_nothing_raised do
          Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")
        end
        assert_equal 1, Part2Label.where(record_type: "tiu_note", record_id: "70001").count
      end

      test "mark! with a blank record id raises rather than writing a row" do
        assert_raises(ActiveRecord::ActiveRecordError) do
          Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "")
        end
        assert_equal 0, Part2Label.count
      end
    end
  end
end
