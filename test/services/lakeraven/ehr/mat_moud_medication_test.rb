# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # #904: the December build offers no MAT/MOUD ordering pathway (42 CFR
    # Part 2, MH-only posture of #522). This discriminator reads medication
    # TEXT only — it does not read RxNorm, NDC or any other code — and it
    # fails closed: text it cannot read is :unclassified, which callers refuse.
    class MatMoudMedicationTest < ActiveSupport::TestCase
      MAT_MOUD_TEXTS = [
        "Buprenorphine-Naloxone 8 mg-2 mg SL film", "SUBOXONE", "Subutex", "Zubsolv", "Bunavail",
        "Sublocade", "Brixadi", "Probuphine", "Butrans 10 mcg/hr patch", "Belbuca", "Buprenex",
        "methadone 10 mg/mL oral concentrate", "Dolophine", "Methadose", "Diskets",
        "naltrexone 50 mg tablet", "Vivitrol 380 mg IM", "Revia",
        "acamprosate 333 mg", "Campral", "disulfiram 250 mg", "Antabuse",
        "lofexidine 0.18 mg", "Lucemyra"
      ].freeze

      MAT_MOUD_TEXTS.each do |text|
        test "classifies #{text.inspect} as :mat_moud from its text alone" do
          assert_equal :mat_moud, MatMoudMedication.classify(text)
        end
      end

      test "case, separators and padding do not hide a MAT/MOUD name" do
        [ "Buprenorphine/Naloxone", "buprenorphine_hcl", "  METHADONE  HCl", "vIvItRoL",
          "Rx: naltrexone,50mg" ].each do |text|
          assert_equal :mat_moud, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "ordinary mental-health and primary-care medications are :not_mat_moud" do
        [ "Sertraline 50 mg tablet", "Lisinopril 10mg", "Ibuprofen 400mg", "Fluoxetine 20 mg capsule" ].each do |text|
          assert_equal :not_mat_moud, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "naloxone alone is overdose reversal, not MOUD" do
        assert_equal :not_mat_moud, MatMoudMedication.classify("Naloxone 4 mg nasal spray")
      end

      test "unreadable text is :unclassified, never :not_mat_moud" do
        [ nil, "", "   ", "\t\n", 12_345, :methadone, [ "Sertraline" ], { name: "Sertraline" } ].each do |value|
          assert_equal :unclassified, MatMoudMedication.classify(value), value.inspect
        end
      end

      # --- Amendment 1 -------------------------------------------------------

      test "a letter outside ASCII a-z after NFKC and downcasing is :unclassified, never :not_mat_moud" do
        [ "meth\u0430done 10 mg", "M\u00E9thadone", "bupren\u043Erphine 8 mg", "Sertralina espa\u00F1ola" ].each do |text|
          assert_equal :unclassified, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "fullwidth letters NFKC-normalise to ASCII and are still read" do
        assert_equal :mat_moud, MatMoudMedication.classify("\uFF33\uFF35\uFF22\uFF2F\uFF38\uFF2F\uFF2E\uFF25")
      end

      test "strings that cannot be read as UTF-8 text are :unclassified and do not raise" do
        [ "methadone\xFF", "Suboxone".encode("UTF-16LE") ].each do |text|
          result = begin
            MatMoudMedication.classify(text)
          rescue StandardError => e
            flunk "#{text.inspect} raised #{e.class}: #{e.message}"
          end
          assert_equal :unclassified, result, text.inspect
        end
      end

      test "short brand names match only as whole words" do
        [ "Ensure via G-tube TID", "Lithium (abbreviated titration)", "Placenta previa iron" ].each do |text|
          assert_equal :not_mat_moud, MatMoudMedication.classify(text), text.inspect
        end
        [ "Revia 50 mg", "REVIA", "Depade 50mg" ].each do |text|
          assert_equal :mat_moud, MatMoudMedication.classify(text), text.inspect
        end
      end

      [ "buprenorphin 8 mg", "buprenorfina", "methadon 10mg", "metadona", "naltrexon", "Suboxon film", "Cassipa",
        "levomethadyl acetate", "LAAM", "BUP 8mg SL", "bup/nx 8-2 film", "Trexan" ].each do |text|
        test "name variant #{text.inspect} is :mat_moud" do
          assert_equal :mat_moud, MatMoudMedication.classify(text)
        end
      end

      test "bupropion is an antidepressant and does not match the bup word stem" do
        assert_equal :not_mat_moud, MatMoudMedication.classify("Bupropion XL 150 mg")
      end

      # --- Amendment 3 -------------------------------------------------------
      # Rule: a non-ASCII character is accepted only when its NFKC form is
      # exactly one printable ASCII character (fullwidth, mathematical bold).
      # The micro sign U+00B5 and Greek mu U+03BC are read as "mc" (dose
      # units). Every other non-ASCII character — symbol, emoji, trademark
      # sign, dash, soft hyphen, zero-width space, combining mark, accented
      # letter — makes the text :unclassified, as does an ASCII control
      # character other than tab, LF and CR.

      {
        "U+212E estimated symbol for e" => "m℮thadone 10 mg",
        "U+1F170 negative squared A" => "meth\u{1F170}done",
        "U+1F17F negative squared P" => "bu\u{1F17F}renorphine 8 mg SL",
        "U+25CB white circle for o" => "methad○ne",
        "U+3007 ideographic zero for o" => "methad〇ne",
        "U+2202 partial differential for a" => "meth∂done",
        "U+2223 divides for l" => "vivitro∣",
        "U+1F1F2 regional indicator M" => "\u{1F1F2}ethadone",
        "U+2122 trademark after Revia" => "Revia™ 50 mg",
        "U+2122 trademark after LAAM" => "LAAM™",
        "U+00AD soft hyphen inside revia" => "re­via 50 mg",
        "U+200B zero-width space inside revia" => "re​via",
        "U+2014 em dash in an ordinary order" => "Sertraline 50 mg — daily",
        "U+0000 NUL inside methadone" => "metha\u0000done"
      }.each do |label, text|
        test "#{label} makes the text :unclassified" do
          assert_equal :unclassified, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "other symbols, combining marks and control characters are :unclassified, never :not_mat_moud" do
        [ "Sertraline 50 mg®", "Sertraline ½ tablet", "Sertraline 50 mg – daily", "Sertraliné 50 mg",
          "Sertraline \u{1F48A}", "Sertraline\u0007 50 mg", "Sertraline\u001B[0m", "Sertraline\u007F" ].each do |text|
          assert_equal :unclassified, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "mathematical bold letters NFKC-normalise to ASCII and are still read" do
        bold = "\u{1D40C}\u{1D41E}\u{1D42D}\u{1D421}\u{1D41A}\u{1D41D}\u{1D428}\u{1D427}\u{1D41E}"
        assert_equal "Methadone", bold.unicode_normalize(:nfkc)
        assert_equal :mat_moud, MatMoudMedication.classify(bold)
      end

      [ "ORLAAM", "Metadol 10 mg" ].each do |text|
        test "brand name #{text.inspect} is :mat_moud" do
          assert_equal :mat_moud, MatMoudMedication.classify(text)
        end
      end

      test "the micro sign and Greek mu are read as mc dose units" do
        assert_equal :not_mat_moud, MatMoudMedication.classify("Levothyroxine 50 µg")
        assert_equal :not_mat_moud, MatMoudMedication.classify("Clonidine 100 μg")
        assert_equal :mat_moud, MatMoudMedication.classify("Butrans 10 µg/hr patch")
      end

      # --- Amendment 4: the micro sign is a dose unit, nothing else ----------
      # µ (U+00B5) / μ (U+03BC) is read as "mc" ONLY when it is preceded by a
      # digit, or by whitespace that follows a digit, AND is immediately
      # followed by an ASCII g or l of either case ("50µg", "50 µg",
      # "100 μL"). Anywhere else it is not a dose unit and makes the text
      # :unclassified: read as "mc" inside a word it would split a name
      # ("methaµdone" reads as "methamcdone", "reµvia" as "remcvia").

      {
        "U+00B5 micro sign inside methadone" => "metha\u00B5done",
        "U+03BC Greek mu inside methadone" => "metha\u03BCdone",
        "U+00B5 micro sign inside revia" => "re\u00B5via 50 mg",
        "U+00B5 micro sign alone" => "\u00B5",
        "U+03BC Greek mu alone" => "\u03BC",
        "U+00B5 micro sign not after a digit" => "Levothyroxine \u00B5g 50",
        "U+03BC Greek mu not after a digit" => "Levothyroxine \u03BCg 50",
        "U+00B5 micro sign not followed by g or l" => "50 \u00B5x",
        "U+00B5 micro sign at the end of the text" => "Levothyroxine 50 \u00B5",
        "U+00B5 micro sign followed by a space before g" => "Levothyroxine 50 \u00B5 g",
        "U+00B5 micro sign after a letter" => "Levothyroxine50mg\u00B5g"
      }.each do |label, text|
        test "#{label} is not a dose unit and makes the text :unclassified" do
          assert_equal :unclassified, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "the micro sign and Greek mu after a dose number and before g or l are still read as mc" do
        [ "Levothyroxine 50\u00B5g", "Levothyroxine 50 \u00B5g", "Levothyroxine 50 \u00B5G", "Clonidine 100 \u03BCg",
          "Vitamin B12 100 \u03BCL", "Vitamin B12 100\u00B5l", "Levothyroxine 50\t\u00B5g" ].each do |text|
          assert_equal :not_mat_moud, MatMoudMedication.classify(text), text.inspect
        end
        [ "Butrans 10 \u00B5g/hr patch", "Butrans 10\u03BCg/hr patch", "methadone 50 \u00B5g" ].each do |text|
          assert_equal :mat_moud, MatMoudMedication.classify(text), text.inspect
        end
      end

      test "tab, LF and CR are ordinary whitespace" do
        assert_equal :not_mat_moud, MatMoudMedication.classify("Sertraline 50 mg\ttablet\n")
        assert_equal :not_mat_moud, MatMoudMedication.classify("Sertraline 50 mg\r\ntablet")
        assert_equal :mat_moud, MatMoudMedication.classify("methadone\t10 mg\r\n")
      end
    end
  end
end
