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
    end
  end
end
