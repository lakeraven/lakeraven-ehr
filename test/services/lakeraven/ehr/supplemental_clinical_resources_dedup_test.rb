# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SupplementalClinicalResourcesDedupTest < ActiveSupport::TestCase
      include SupplementalProviderConfigHelper

      DFN = "1"

      # Mirrors AllergyIntoleranceGateway assessment capture so wire_allergy_reply
      # sees assessed NKA with an empty allergy list.
      class NkaWireGateway
        class << self
          attr_accessor :patient_wire_rows

          def begin_assessment_capture!
            @capture = true
            @mark = nil
          end

          def end_assessment_capture!
            @capture = false
          end

          def for_patient(_dfn)
            rows = patient_wire_rows.nil? ? [] : Array(patient_wire_rows)
            if @capture
              @mark = if rows.empty?
                { assessed: true, nka: true, rows: rows }
              else
                { assessed: true, nka: false, rows: rows }
              end
            end
            rows
          end

          def take_assessment(rows)
            return unless @mark && @mark[:rows].equal?(rows)

            { assessed: @mark[:assessed], nka: @mark[:nka] }
          end
        end
      end

      def with_nka_wire_gateway(wire_rows: nil)
        original = AllergyIntolerance.gateway
        NkaWireGateway.patient_wire_rows = wire_rows
        AllergyIntolerance.gateway = NkaWireGateway
        yield
      ensure
        AllergyIntolerance.gateway = original
        NkaWireGateway.patient_wire_rows = nil
      end

      def allergy_reading_for_patient(dfn, supplemental_rows, wire_rows: nil)
        with_nka_wire_gateway(wire_rows: wire_rows) do
          with_supplemental_providers(allergy_intolerances: ->(_dfn) { supplemental_rows }) do
            SupplementalClinicalResources.send(:allergy_intolerance_reading_for_patient, dfn)
          end
        end
      end

      test "differing duplicate ien increments dropped_count" do
        latex = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        peanut = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Peanut", clinical_status: "active"
        )

        reading = allergy_reading_for_patient(DFN, [ latex, peanut ])

        assert_equal 1, reading.size
        assert_includes reading.map(&:allergen), "Latex"
        assert reading.dropped_count >= 1,
               "expected merge de-dupe of differing matching_key rows to count as dropped"
      end

      test "same-allergy duplicate ien does not add to dropped_count" do
        single = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        baseline = allergy_reading_for_patient(DFN, [ single ])

        duplicate_a = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        duplicate_b = AllergyIntolerance.new(
          ien: "x", patient_dfn: DFN, allergen: "Latex", clinical_status: "active"
        )
        with_duplicates = allergy_reading_for_patient(DFN, [ duplicate_a, duplicate_b ])

        assert_equal baseline.dropped_count, with_duplicates.dropped_count,
                     "same matching_key duplicate must not increase dropped_count"
        assert_equal 1, with_duplicates.size
        assert_equal [ "Latex" ], with_duplicates.map(&:allergen)
      end

      # Pin (fail closed): two rows sharing an ien are the SAME allergy only when
      # normalised names (strip, downcase, squish) are both non-blank and equal,
      # AND when both rows carry a valid code the codes are equal. A valid code is
      # all digits after strip and not all zeros; compare with leading zeros removed.
      # Placeholder/non-numeric/all-zero codes are ignored (no code). Anything else
      # counts toward dropped_count.
      def wire_allergy(ien:, allergen:, allergen_code: nil)
        AllergyIntolerance.new(
          ien: ien,
          patient_dfn: DFN,
          allergen: allergen,
          allergen_code: allergen_code,
          clinical_status: "active"
        )
      end

      test "same ien coded supplemental mirror of uncoded wire row same name does not drop" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        mirror = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ mirror ], wire_rows: [ wire ])

        assert_equal 0, reading.dropped_count,
                     "uncoded ORQQAL row and coded supplemental mirror with same name share ien 5"
      end

      test "same ien coded supplemental mirror matches wire name case and whitespace" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        mirror = wire_allergy(ien: "5", allergen: "penicillin ", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ mirror ], wire_rows: [ wire ])

        assert_equal 0, reading.dropped_count,
                     "name comparison under (b) must ignore case and extra whitespace"
      end

      test "same ien both coded different codes same display name counts as dropped" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        other_code = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "1234")

        reading = allergy_reading_for_patient(DFN, [ other_code ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "conflicting rxnorm codes on one ien must not read as one allergy"
      end

      test "same ien coded vs uncoded different names counts as dropped" do
        wire = wire_allergy(ien: "5", allergen: "Latex")
        coded = wire_allergy(ien: "5", allergen: "Peanut", allergen_code: "891658")

        reading = allergy_reading_for_patient(DFN, [ coded ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "Latex and Peanut on one ien must count as a list hole"
      end

      test "same ien both coded same code different name text counts as dropped" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin G", allergen_code: "7980")
        alias_row = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ alias_row ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "equal codes without equal normalised names must not read as one allergy"
      end

      # Adversarial review (issue 466): repeat ien must count dropped when ANY prior row
      # on that ien is a different allergy, not only the first kept row.
      test "(a) same ien uncoded wire then two conflicting coded supplemental rows counts dropped" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        coded_7980 = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        coded_1234 = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "1234")

        reading = allergy_reading_for_patient(DFN, [ coded_7980, coded_1234 ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "7980 and 1234 on one ien must count as dropped even when first repeat matched uncoded wire by name"
      end

      test "(b) same ien coded wire then uncoded and conflicting coded supplemental counts dropped" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        uncoded = wire_allergy(ien: "5", allergen: "Penicillin")
        coded_1234 = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "1234")

        reading = allergy_reading_for_patient(DFN, [ uncoded, coded_1234 ], wire_rows: [ wire ])

        assert reading.dropped_count >= 1,
               "conflicting rxnorm on one ien must count dropped regardless of row order"
      end

      test "(c) same ien uncoded wire coded mirror and normalised-name duplicate does not drop" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        coded_7980 = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        uncoded_alias = wire_allergy(ien: "5", allergen: "penicillin ")

        reading = allergy_reading_for_patient(DFN, [ coded_7980, uncoded_alias ], wire_rows: [ wire ])

        assert_equal 0, reading.dropped_count,
                     "all rows are the same allergy under coded-or-name rules"
      end

      # Placeholder allergen_code values must not identify an allergy unless numeric.
      test "(d) same ien equal non-numeric placeholder codes different names counts dropped" do
        penicillin_unk = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "UNK")
        peanut_unk = wire_allergy(ien: "5", allergen: "Peanut", allergen_code: "UNK")

        reading = allergy_reading_for_patient(DFN, [ penicillin_unk, peanut_unk ])

        assert reading.dropped_count >= 1,
               "UNK must not make Penicillin and Peanut the same allergy on one ien"
      end

      test "(e) same ien all-zero numeric placeholder code different names counts dropped" do
        penicillin_zero = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "0")
        peanut_zero = wire_allergy(ien: "5", allergen: "Peanut", allergen_code: "0")

        reading = allergy_reading_for_patient(DFN, [ penicillin_zero, peanut_zero ])

        assert reading.dropped_count >= 1,
               "0 is not a valid code; Penicillin and Peanut on one ien must count as dropped"
      end

      test "(e2) same ien triple-zero placeholder code different names counts dropped" do
        penicillin = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "000")
        peanut = wire_allergy(ien: "5", allergen: "Peanut", allergen_code: "000")

        reading = allergy_reading_for_patient(DFN, [ penicillin, peanut ])

        assert reading.dropped_count >= 1,
               "000 is not a valid code; differing names on one ien must count as dropped"
      end

      test "same ien blank-named coded row then coded Peanut counts as dropped" do
        blank_first = wire_allergy(ien: "5", allergen: "", allergen_code: "7980")
        peanut = wire_allergy(ien: "5", allergen: "Peanut", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ blank_first, peanut ])

        assert reading.dropped_count >= 1,
               "blank name cannot match Peanut; Peanut must not be hidden as a duplicate"
      end

      test "same ien coded codes equal after stripping leading zeros does not drop" do
        leading_zeros = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "07980")
        canonical = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ canonical ], wire_rows: [ leading_zeros ])

        assert_equal 0, reading.dropped_count,
                     "07980 and 7980 are the same valid code with matching names"
      end

      test "same ien both coded same code normalised name match does not drop" do
        first = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        second = wire_allergy(ien: "5", allergen: "penicillin ", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ second ], wire_rows: [ first ])

        assert_equal 0, reading.dropped_count,
                     "7980 rows with equal normalised names are one allergy"
      end

      test "same ien supplemental only uncoded Penicillin and coded 7980 mirror does not drop" do
        uncoded = wire_allergy(ien: "5", allergen: "Penicillin")
        coded = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")

        reading = allergy_reading_for_patient(DFN, [ uncoded, coded ])

        assert_equal 0, reading.dropped_count,
                     "uncoded row with valid coded mirror and same name is one allergy"
      end

      test "same ien both coded different valid codes same name counts as dropped" do
        code_7980 = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        code_1234 = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "1234")

        reading = allergy_reading_for_patient(DFN, [ code_1234 ], wire_rows: [ code_7980 ])

        assert reading.dropped_count >= 1,
               "7980 and 1234 on one ien with same display name must count as dropped"
      end

      test "same ien three thousand identical coded rows completes under one second" do
        rows = Array.new(3_000) do
          wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "7980")
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reading = allergy_reading_for_patient(DFN, rows)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_operator elapsed, :<, 1.0,
                        "3000 same-ien rows must not take quadratic time (was ~7.2s at head)"
        assert_equal 0, reading.dropped_count,
                     "identical rows are one allergy"
        assert_equal 1, reading.size
      end

      test "(f) same ien equal non-numeric placeholder codes same name does not drop" do
        first = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "UNK")
        second = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: "UNK")

        reading = allergy_reading_for_patient(DFN, [ first, second ])

        assert_equal 0, reading.dropped_count,
                     "duplicate Penicillin rows with UNK placeholder are one allergy"
      end

      # Pin fail-closed: allergen bytes tagged UTF-8 but invalid must not raise
      # during normalisation; unreadable names are never the same allergy (like
      # malformed codes).
      def invalid_utf8_allergen_label
        (+"Synth\xC9").force_encoding("UTF-8")
      end

      def merge_allergies_result(wire_rows, supplemental_rows)
        SupplementalClinicalResources.send(:merge_allergies, wire_rows, supplemental_rows)
      end

      test "invalid utf8 allergen name on separate ien does not raise and keeps wire row" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        unreadable = wire_allergy(ien: "9", allergen: invalid_utf8_allergen_label)

        records, _dropped = merge_allergies_result([ wire ], [ unreadable ])

        assert_equal 2, records.size
        assert_includes records.map(&:allergen), "Penicillin"
      end

      test "invalid utf8 name on same ien as readable row does not raise and counts dropped" do
        readable = wire_allergy(ien: "5", allergen: "Penicillin")
        unreadable = wire_allergy(ien: "5", allergen: invalid_utf8_allergen_label)

        _records, dropped = merge_allergies_result([ readable ], [ unreadable ])

        assert dropped >= 1,
               "unreadable name must not match Penicillin on the same ien"
      end

      test "invalid utf8 duplicate names on one ien do not raise and count dropped" do
        unreadable_a = wire_allergy(ien: "5", allergen: invalid_utf8_allergen_label)
        unreadable_b = wire_allergy(ien: "5", allergen: invalid_utf8_allergen_label.dup)

        _records, dropped = merge_allergies_result([], [ unreadable_a, unreadable_b ])

        assert dropped >= 1,
               "unreadable identity must not match even a repeat of the same bytes"
      end

      test "reading path keeps Penicillin when supplemental row has invalid utf8 name on other ien" do
        wire = wire_allergy(ien: "5", allergen: "Penicillin")
        unreadable = wire_allergy(ien: "9", allergen: invalid_utf8_allergen_label)

        reading = allergy_reading_for_patient(DFN, [ unreadable ], wire_rows: [ wire ])

        assert_includes reading.map(&:allergen), "Penicillin"
      end

      # Issue 466 option (b): normalise code forms before valid/placeholder/differing
      # decisions (ASCII digits, Unicode whitespace, integral *.0 decimals).
      CODE_PAIR_EXPECT_ONE_DROP = [
        [ "1234", "5678.0" ],
        [ "111", "２２２" ],
        [ "123", "\u00a0456" ],
        [ "1234", "ABC" ],
        [ "1234", "12-34" ],
        [ "1234", "5678.5" ]
      ].freeze

      CODE_PAIR_EXPECT_NO_DROP = [
        [ "1234", "UNK" ],
        [ "1234", "unk " ],
        [ "1234", "0" ],
        [ "1234", "000" ],
        [ "7980", "7980.0" ],
        [ "7980", "０７９８０" ],
        [ "7980", " \u00a07980\u00a0" ],
        [ "7980", "07980" ]
      ].freeze

      def assert_allergy_code_pair_dropped_count(expected_drops, code_a, code_b, pair_label)
        row_a = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: code_a)
        row_b = wire_allergy(ien: "5", allergen: "Penicillin", allergen_code: code_b)

        [
          allergy_reading_for_patient(DFN, [ row_b ], wire_rows: [ row_a ]),
          allergy_reading_for_patient(DFN, [ row_a ], wire_rows: [ row_b ])
        ].each do |reading|
          assert_equal expected_drops, reading.dropped_count, pair_label
        end
      end

      test "option (b) code normalisation pairs that must count as different allergy on one ien" do
        CODE_PAIR_EXPECT_ONE_DROP.each do |code_a, code_b|
          pair_label = %(expected dropped_count 1 for #{code_a.inspect} vs #{code_b.inspect})
          assert_allergy_code_pair_dropped_count(1, code_a, code_b, pair_label)
        end
      end

      test "option (b) code normalisation pairs that remain the same allergy on one ien" do
        CODE_PAIR_EXPECT_NO_DROP.each do |code_a, code_b|
          pair_label = %(expected dropped_count 0 for #{code_a.inspect} vs #{code_b.inspect})
          assert_allergy_code_pair_dropped_count(0, code_a, code_b, pair_label)
        end
      end
    end
  end
end
