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

      # --- empty text: :not_suspected ---

      test "an empty String is not suspected" do
        assert_equal :not_suspected, SudContentSuspicion.classify("")
      end

      test "a whitespace-only String is not suspected" do
        assert_equal :not_suspected, SudContentSuspicion.classify("  \n\t ")
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
