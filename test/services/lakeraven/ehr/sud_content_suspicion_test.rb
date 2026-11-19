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

      # --- vocabulary gaps found in review (#906 round 3) ---
      # Bare "drug(s)" and "substance(s)", dependence in a use context,
      # DSM-style "<class> use disorder" names, and more everyday and brand
      # names. Over-labelling is the fail-closed direction.

      ROUND3_SUSPECTED = [
        # bare drug / substance
        "Pt admits to using drugs.", "uses street drugs", "drug problem",
        "drug screen positive", "using substances again", "IV drug use",
        # dependence in a use context
        "substance dependence", "substance-induced mood disorder", "chemical dependency",
        # DSM-style names
        "stimulant use disorder, moderate", "sedative use disorder", "inhalant use",
        "hallucinogen use",
        # substances and medications
        "opium", "tramadol", "Klonopin", "Valium", "Ativan", "Dilaudid", "MDMA",
        "ecstasy", "LSD", "whiskey",
        # everyday wording
        "hangover", "hung over", "twelve-step", "SUDs", "in recovery from alcohol",
        "got high last night", "nonalcoholic beer"
      ].freeze

      ROUND3_SUSPECTED.each do |text|
        test "the round 3 text #{text.inspect} is suspected" do
          assert_equal :suspected, SudContentSuspicion.classify(text)
        end

        test "the round 3 text #{text.inspect} inside a sentence is suspected" do
          assert_equal :suspected,
            SudContentSuspicion.classify("Session note: #{text}; discussed with client.")
        end
      end

      # Guards: the round 3 terms must not over-match these. "independent"
      # is not "dependence", and "highly" is not "got high".
      ROUND3_NOT_SUSPECTED = [
        "Client feels highly motivated",
        "independent living skills reviewed",
        "Client is a teacher (AAA member)",
        "Z71.3 dietary counselling",
        "F3210"
      ].freeze

      ROUND3_NOT_SUSPECTED.each do |text|
        test "the round 3 guard text #{text.inspect} is not suspected" do
          assert_equal :not_suspected, SudContentSuspicion.classify(text)
        end
      end

      # --- separators and invisible characters (#906 round 3) ---
      # A term or a code is still a term or a code when its words are joined
      # by an underscore or any dash, when an invisible character sits inside
      # it, or when it is written in fullwidth forms.

      SEPARATOR_SUSPECTED = {
        "an underscore inside a phrase" => "substance_use: yes",
        "an underscore before a term" => "hx_alcohol: positive",
        "an underscore inside a code" => "F10_20",
        "an en dash inside a phrase" => "substance–use disorder",
        "a non-breaking hyphen inside a phrase" => "substance‑use",
        "a soft hyphen inside a term" => "alco­hol",
        "a zero-width space inside a term" => "alco​hol",
        "a fullwidth term" => "ａｌｃｏｈｏｌ",
        "a fullwidth code" => "Dx Ｆ１０.20"
      }.freeze

      SEPARATOR_SUSPECTED.each do |name, text|
        test "#{name} is suspected" do
          assert_equal :suspected, SudContentSuspicion.classify(text)
        end

        test "#{name} inside a sentence is suspected" do
          assert_equal :suspected,
            SudContentSuspicion.classify("Session note: #{text}; discussed with client.")
        end
      end

      # --- no readable content: :unclassified (#906 round 3) ---
      # Text with no letter or digit in it says nothing about what the record
      # holds. It is absence of data, not evidence of cleanliness.

      NO_READABLE_CONTENT = {
        "a zero-width space only" => "​",
        "a byte-order mark only" => "﻿",
        "a NUL only" => "\u0000",
        "a full stop only" => ".",
        "dashes only" => "--",
        "spaces and invisible characters only" => " ​ ﻿ "
      }.freeze

      NO_READABLE_CONTENT.each do |name, text|
        test "#{name} is unclassified" do
          result = nil
          assert_nothing_raised { result = SudContentSuspicion.classify(text) }
          assert_equal :unclassified, result
        end
      end

      [ "ok", "Seen." ].each do |text|
        test "the short clean text #{text.inspect} is not suspected" do
          assert_equal :not_suspected, SudContentSuspicion.classify(text)
        end
      end

      # --- classify never raises on a String (#906 round 3) ---

      # Makes every regex match issued from sud_content_suspicion.rb raise
      # Regexp::TimeoutError for the block, however many patterns there are
      # and whichever match method is used. Matches issued from anywhere else
      # are untouched. Yields an Array that collects one entry per raise.
      REGEX_MATCH_METHODS = %i[match? match =~ === scan index].freeze

      def with_sud_regex_timeout
        fired = []
        trace = TracePoint.new(:c_call) do |tp|
          next unless REGEX_MATCH_METHODS.include?(tp.method_id)
          next unless tp.defined_class == Regexp || tp.defined_class == String
          next unless tp.path.to_s.end_with?("sud_content_suspicion.rb")

          fired << tp.method_id
          raise Regexp::TimeoutError, "synthetic: regex match timed out"
        end
        trace.enable { yield fired }
      end

      [ "Discussed sleep hygiene and work stress; PHQ-9 reviewed.", "heroin" ].each do |text|
        test "a regex timeout while reading #{text.inspect} is unclassified and does not raise" do
          with_sud_regex_timeout do |fired|
            result = nil
            assert_nothing_raised { result = SudContentSuspicion.classify(text) }
            assert_equal :unclassified, result
            refute_empty fired, "the synthetic regex timeout never fired"
          end
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

      # --- control characters inside a term (#906 review) ---
      # A non-whitespace control character keyed inside a term must not make
      # the text read clean. Either answer is acceptable: :suspected (the
      # control character is removed before matching) or :unclassified.

      { "a NUL" => "alco\u0000hol",
        "a C0 control (U+0001)" => "alco\u0001hol",
        "a backspace" => "alco\bhol",
        "a DEL (U+007F)" => "alco\u007Fhol",
        "a C1 control (U+0090)" => "alco\u0090hol" }.each do |name, text|
        test "a term split by #{name} is never not_suspected" do
          refute_equal :not_suspected, SudContentSuspicion.classify(text), text.inspect
        end

        test "a term split by #{name} inside a sentence is never not_suspected" do
          sentence = "Seen for follow-up. Reports #{text} nightly. Vitals stable."
          refute_equal :not_suspected, SudContentSuspicion.classify(sentence), sentence.inspect
        end
      end

      test "UTF-16LE bytes of a term read as UTF-8 are never not_suspected" do
        text = "a\0l\0c\0o\0h\0o\0l\0"
        assert_equal Encoding::UTF_8, text.encoding
        assert text.valid_encoding?

        refute_equal :not_suspected, SudContentSuspicion.classify(text)
      end

      test "ordinary whitespace controls still separate words in clean text" do
        assert_equal :not_suspected, SudContentSuspicion.classify("Seen.\tVitals stable.\nNo concerns.")
        assert_equal :not_suspected, SudContentSuspicion.classify("Seen.\r\nVitals stable.\r\nNo concerns.")
      end

      test "a term followed by a tab is still read" do
        refute_equal :not_suspected, SudContentSuspicion.classify("alcohol\tuse")
        refute_equal :not_suspected, SudContentSuspicion.classify("Reports\nalcohol\nuse")
      end

      # --- a control or format character as the ONLY separator (#906 review) ---
      # Removing these characters glues the neighbouring words together
      # ("used<US>heroin" -> "usedheroin"), so the term no longer starts a
      # word and is missed. The text is read in both canonical forms (the
      # character removed, and the character read as a space) and is
      # :suspected when either form matches.

      { "a unit separator (U+001F) in a sentence" => "patient used\x1Fheroin daily",
        "a unit separator (U+001F)" => "used\x1Fheroin",
        "a NUL (U+0000)" => "used\x00heroin",
        "an ESC (U+001B)" => "used\eheroin",
        "a DEL (U+007F)" => "used\x7Fheroin",
        "a C1 control (U+0090)" => "used\u0090heroin",
        "a C1 control (U+009B)" => "used\u009Bheroin",
        "a zero-width space (U+200B)" => "used​heroin",
        "a word joiner (U+2060)" => "used⁠heroin",
        "a BOM (U+FEFF)" => "used﻿heroin" }.each do |name, text|
        test "a term separated from the word before it only by #{name} is suspected" do
          assert_equal :suspected, SudContentSuspicion.classify(text),
                       "#{name} was the only separator in #{text.inspect}"
        end
      end

      test "a term separated only by a control character on both sides is suspected" do
        text = "Reports\x1Fheroin\x1Fuse nightly."
        assert_equal :suspected, SudContentSuspicion.classify(text), text.inspect
      end

      test "a multi-word phrase whose words are separated only by a control character is suspected" do
        text = "attends twelve\x1Fstep meetings"
        assert_equal :suspected, SudContentSuspicion.classify(text), text.inspect
      end

      test "an ICD-10-CM substance-use code separated only by a control character is suspected" do
        text = "Dx\x1FF10.20 noted"
        assert_equal :suspected, SudContentSuspicion.classify(text), text.inspect
      end

      # Regression guards: the removed form still matches, and a control
      # separator alone never makes clean text suspected.

      test "a term split by a NUL or a soft hyphen is still suspected" do
        assert_equal :suspected, SudContentSuspicion.classify("alco\u0000hol")
        assert_equal :suspected, SudContentSuspicion.classify("alco­hol")
      end

      test "a control character separating clean words does not make the text suspected" do
        assert_equal :not_suspected, SudContentSuspicion.classify("patient\x1Fwell today")
        assert_equal :not_suspected, SudContentSuspicion.classify("patient​well today")
      end
    end
  end
end
