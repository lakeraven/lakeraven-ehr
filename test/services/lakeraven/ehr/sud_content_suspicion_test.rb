# frozen_string_literal: true

require "test_helper"

# SudContentSuspicion reads free text (a progress note) and answers whether
# it looks like substance-use content (#906, slice of #522). It labels; it
# never blocks. Text it cannot read is :unclassified, which is not evidence
# of safety. Over-labelling is the fail-closed direction.
module Lakeraven
  module EHR
    class SudContentSuspicionTest < ActiveSupport::TestCase
      # --- unreadable input: :unclassified ---

      test "nil is unclassified" do
        assert_equal :unclassified, SudContentSuspicion.classify(nil)
      end

      test "an Integer is unclassified" do
        assert_equal :unclassified, SudContentSuspicion.classify(42)
      end

      test "a Hash is unclassified" do
        assert_equal :unclassified, SudContentSuspicion.classify({ text: "Discussed sleep hygiene." })
      end

      test "an Array is unclassified" do
        assert_equal :unclassified, SudContentSuspicion.classify([ "Discussed sleep hygiene." ])
      end

      # --- blank text: :unclassified ---
      # Absence of data never verifies a record as clean: a blank note says
      # nothing about what the record holds.

      test "an empty String is unclassified" do
        assert_equal :unclassified, SudContentSuspicion.classify("")
      end

      test "a whitespace-only String is unclassified" do
        assert_equal :unclassified, SudContentSuspicion.classify("  \n\t ")
      end

      # --- text that cannot be read: :unclassified, never an exception ---

      # A String tagged UTF-8 that carries a byte sequence that is not UTF-8.
      def invalid_utf8_text
        "Pt seen today, caf\xE9".dup.force_encoding("UTF-8")
      end

      test "a String with an invalid byte sequence is unclassified and does not raise" do
        text = invalid_utf8_text
        refute text.valid_encoding?, "the synthetic text should be invalid UTF-8"

        result = nil
        assert_nothing_raised { result = SudContentSuspicion.classify(text) }
        assert_equal :unclassified, result
      end

      test "a String in a non-ASCII-compatible encoding is unclassified and does not raise" do
        text = "sleep hygiene".encode("UTF-16LE")
        refute text.encoding.ascii_compatible?, "the synthetic text should not be ASCII-compatible"

        result = nil
        assert_nothing_raised { result = SudContentSuspicion.classify(text) }
        assert_equal :unclassified, result
      end

      # --- vocabulary: :suspected ---

      VOCABULARY = [
        "alcohol", "Opioid", "heroin", "fentanyl", "methamphetamine", "cocaine",
        "cannabis", "marijuana", "substance use", "overdose", "buprenorphine",
        "methadone", "naloxone", "withdrawal", "relapse", "drinking"
      ].freeze

      VOCABULARY.each do |term|
        test "text mentioning #{term.inspect} is suspected" do
          assert_equal :suspected,
            SudContentSuspicion.classify("Client spoke about #{term} during the session.")
        end

        test "the bare term #{term.inspect} is suspected" do
          assert_equal :suspected, SudContentSuspicion.classify(term)
        end
      end

      test "matching is case-insensitive" do
        assert_equal :suspected, SudContentSuspicion.classify("HEROIN")
        assert_equal :suspected, SudContentSuspicion.classify("opioid")
        assert_equal :suspected, SudContentSuspicion.classify("Client reports Substance Use in the past.")
        assert_equal :suspected, SudContentSuspicion.classify("FeNtAnYl")
      end

      test "a term on a later line of a multi-line note is suspected" do
        text = "Discussed sleep hygiene.\nReviewed PHQ-9.\nClient mentioned a relapse last month."
        assert_equal :suspected, SudContentSuspicion.classify(text)
      end

      test "a negated mention is still suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("Client denies alcohol use")
        assert_equal :suspected, SudContentSuspicion.classify("No history of opioid misuse.")
      end

      # --- word stems: a term matches at a word start ---

      %w[alcoholic alcoholism opioids drinks].each do |word|
        test "the word-start form #{word.inspect} is suspected" do
          assert_equal :suspected, SudContentSuspicion.classify("Family history: #{word}.")
        end
      end

      test "alcoholics anonymous is suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("Attends alcoholics anonymous weekly.")
      end

      test "meth alone is suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("meth")
      end

      test "meth use is suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("Client disclosed meth use last year.")
      end

      # --- ICD-10-CM F10-F19 written in the text ---

      test "an F11 code written in the text is suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("Dx F11.20 noted")
      end

      test "a lower-case F10 code is suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("f10.10")
      end

      test "an F19 code is suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("Carried forward: F19.20.")
      end

      # --- vocabulary and pattern gaps found in review (#906 round 2) ---

      GAP_SUSPECTED = [
        # phrasing variants
        "substance-use disorder", "substance\u00A0use", "polysubstance abuse",
        "substance misuse", "drug misuse", "drug-seeking behaviour",
        "illicit drugs", "recreational drug use",
        # everyday wording
        "clean and sober 6 months", "drank heavily", "in rehab", "binge episodes",
        "blackout last weekend", "hungover at session",
        # abbreviations, as whole words
        "hx SUD", "OUD", "AUD in remission", "IVDU", "THC positive",
        "DUI last year", "UDS positive", "attends AA weekly", "12-step program",
        "narcotics anonymous",
        # substances and medications
        "oxycodone", "hydrocodone", "Percocet", "morphine", "benzos",
        "benzodiazepine", "Xanax", "amphetamine", "ketamine", "kratom", "weed",
        "beer", "wine", "vodka", "liquor", "Subutex", "Vivitrol", "Antabuse",
        "disulfiram",
        # codes written in the text: undotted F10-F19, and the Z71.4/Z71.5
        # counselling codes Icd10CmSubstanceUseRange already reads as substance use
        "F1120", "f1010", "Z71.41", "Z71.51"
      ].freeze

      GAP_SUSPECTED.each do |text|
        test "the gap text #{text.inspect} is suspected" do
          assert_equal :suspected, SudContentSuspicion.classify(text)
        end

        test "the gap text #{text.inspect} inside a sentence is suspected" do
          assert_equal :suspected,
            SudContentSuspicion.classify("Session note: #{text}, discussed with client.")
        end
      end

      %w[sud oud aud ivdu thc dui uds].each do |abbreviation|
        test "the abbreviation #{abbreviation.inspect} matches in lower case" do
          assert_equal :suspected, SudContentSuspicion.classify("hx #{abbreviation} noted")
        end
      end

      # Guards against the new terms over-matching.
      GAP_NOT_SUSPECTED = [
        "Reviewed methodology of the worksheet",
        "Discussed sleep hygiene and work stress; PHQ-9 reviewed.",
        "Dx F32.1 noted", "F20.0", "F3210", "Z71.3 dietary counselling",
        "Mattress shopping", "Client is a teacher (AAA member)"
      ].freeze

      GAP_NOT_SUSPECTED.each do |text|
        test "the guard text #{text.inspect} is not suspected" do
          assert_equal :not_suspected, SudContentSuspicion.classify(text)
        end
      end

      # --- clean text: :not_suspected ---

      test "an ordinary mental-health note is not suspected" do
        assert_equal :not_suspected,
          SudContentSuspicion.classify("Discussed sleep hygiene and work stress; PHQ-9 reviewed.")
      end

      test "methodology does not match meth" do
        assert_equal :not_suspected, SudContentSuspicion.classify("Reviewed methodology of the worksheet")
      end

      test "an unrelated everyday phrase is not suspected" do
        assert_equal :not_suspected, SudContentSuspicion.classify("Mattress shopping")
      end

      test "an ICD code outside F10-F19 is not suspected on its own" do
        assert_equal :not_suspected, SudContentSuspicion.classify("Dx F32.1 noted")
        assert_equal :not_suspected, SudContentSuspicion.classify("F20.0")
      end

      test "classify only ever answers one of the three symbols" do
        [ nil, 7, {}, [], "", "   ", "heroin", "Discussed sleep hygiene." ].each do |input|
          assert_includes %i[suspected not_suspected unclassified], SudContentSuspicion.classify(input)
        end
      end
    end
  end
end
