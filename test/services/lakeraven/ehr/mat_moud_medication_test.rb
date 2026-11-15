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
    end
  end
end
