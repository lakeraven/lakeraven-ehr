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

      # --- mark! normalises the ids it stores ---

      test "mark! strips surrounding whitespace from record_id" do
        Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: " 70001 ")

        assert_equal [ "70001" ], Part2Label.pluck(:record_id)
      end

      test "mark! stores record_type lower-case" do
        Part2Label.mark!(patient_dfn: "9001", record_type: "TIU_NOTE", record_id: "70001")

        assert_equal [ "tiu_note" ], Part2Label.pluck(:record_type)
      end

      # --- mark! refuses a NUL byte anywhere in an id ---
      # String#strip removes leading and trailing NUL bytes along with
      # whitespace. A malformed id must be refused, not quietly stored under
      # the id it resembles.

      {
        "a leading NUL in record_id" => { record_type: "tiu_note", record_id: "\u000070001" },
        "a trailing NUL in record_id" => { record_type: "tiu_note", record_id: "70001\u0000" },
        "an inner NUL in record_id" => { record_type: "tiu_note", record_id: "7\u00001" },
        "a leading NUL in record_type" => { record_type: "\u0000tiu_note", record_id: "70001" },
        "a trailing NUL in record_type" => { record_type: "tiu_note\u0000", record_id: "70001" },
        "an inner NUL in record_type" => { record_type: "tiu\u0000note", record_id: "70001" },
        "a trailing NUL wrapped in whitespace in record_id" => { record_type: "tiu_note", record_id: " 70001\u0000 " }
      }.each do |name, record|
        test "mark! with #{name} raises RecordInvalid and writes no row" do
          assert_no_difference "Part2Label.count" do
            assert_raises(ActiveRecord::RecordInvalid) do
              Part2Label.mark!(patient_dfn: "1001", **record)
            end
          end
        end
      end

      {
        "a leading NUL in record_id" => { record_type: "tiu_note", record_id: "\u000070001" },
        "a trailing NUL in record_id" => { record_type: "tiu_note", record_id: "70001\u0000" },
        "a leading NUL in record_type" => { record_type: "\u0000tiu_note", record_id: "70001" },
        "a trailing NUL in record_type" => { record_type: "tiu_note\u0000", record_id: "70001" }
      }.each do |name, record|
        test "the normalized key for #{name} is not storable" do
          key = Part2Label.normalized_key(**record)

          assert_equal false, Part2Label.storable_key?(key)
        end
      end

      test "the normalized key still strips ordinary surrounding whitespace" do
        key = Part2Label.normalized_key(record_type: " TIU_NOTE ", record_id: " 70001\n")

        assert_equal({ record_type: "tiu_note", record_id: "70001" }, key)
        assert_equal true, Part2Label.storable_key?(key)
      end

      # --- mark! and a concurrent writer ---

      # Part2Label.find_by answers nil on its FIRST call and is the real
      # find_by afterwards: mark!'s initial lookup misses a row that a
      # concurrent writer commits a moment later.
      def with_first_find_by_missing
        calls = 0
        restore = singleton_method_restore(Part2Label, :find_by)
        Part2Label.define_singleton_method(:find_by) do |*args, **kwargs|
          calls += 1
          calls == 1 ? nil : super(*args, **kwargs)
        end
        yield
      ensure
        restore&.call
      end

      # The uniqueness VALIDATION is a SELECT, so in a real race it also runs
      # before the other writer commits and sees nothing; only the unique
      # index catches the duplicate. A single connection cannot reproduce that
      # timing, so for the block the framework's uniqueness validator is told
      # to see nothing for Part2Label records (every other model keeps the
      # real validator). No production code path is removed: the INSERT and
      # the unique index run for real.
      def with_uniqueness_check_seeing_nothing
        validator = ActiveRecord::Validations::UniquenessValidator
        original = validator.instance_method(:validate_each)
        validator.send(:define_method, :validate_each) do |record, attribute, value|
          next if record.is_a?(Part2Label)

          original.bind_call(self, record, attribute, value)
        end
        yield
      ensure
        validator.send(:define_method, :validate_each, original) if original
      end

      test "mark! returns the existing row when a concurrent writer wins after the lookup" do
        existing = Part2Label.create!(VALID)
        marked = nil

        with_first_find_by_missing do
          assert_nothing_raised do
            marked = Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")
          end
        end

        assert_equal existing.id, marked&.id
        assert_equal 1, Part2Label.where(record_type: "tiu_note", record_id: "70001").count
      end

      test "a unique-index refusal inside mark! does not abort the caller's transaction" do
        existing = Part2Label.create!(VALID)
        marked = nil
        count_after = nil

        with_first_find_by_missing do
          with_uniqueness_check_seeing_nothing do
            assert_nothing_raised do
              Part2Label.transaction do
                marked = Part2Label.mark!(patient_dfn: "9001", record_type: "tiu_note", record_id: "70001")
                # The caller's transaction must still be usable (no
                # PG::InFailedSqlTransaction).
                count_after = Part2Label.count
              end
            end
          end
        end

        assert_equal existing.id, marked&.id
        assert_equal 1, count_after
        assert_equal 1, Part2Label.where(record_type: "tiu_note", record_id: "70001").count
      end
    end
  end
end
