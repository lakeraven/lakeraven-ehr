# frozen_string_literal: true

module Lakeraven
  module EHR
    # Discriminator every ordering entry point uses for #904: the December
    # build (MH-only clinic, Part 2 posture of #522) offers no MAT/MOUD
    # ordering pathway.
    #
    # This is not a Part 2 classifier. It reads medication TEXT only — it
    # does not read RxNorm, NDC or any other code, nor diagnoses, labs or
    # notes. Text it cannot read is :unclassified, and callers refuse that:
    # unreadable text is not evidence the order is safe to place.
    class MatMoudMedication
      # Generic and brand names of medications for opioid and alcohol use
      # disorder (buprenorphine, methadone, naltrexone, acamprosate,
      # disulfiram, lofexidine). Naloxone ALONE is deliberately EXCLUDED: it is
      # overdose reversal, not MOUD. Buprenorphine/naloxone combinations are
      # caught by their buprenorphine or brand name.
      #
      # NOT EXHAUSTIVE, and the code must not pretend otherwise. Other brands,
      # misspellings and compounded products exist. :not_mat_moud is a
      # statement about THIS list and not a clinical safety claim.
      NAMES = %w[
        buprenorphine suboxone subutex zubsolv bunavail sublocade brixadi
        probuphine butrans belbuca buprenex
        methadone dolophine methadose diskets
        naltrexone vivitrol revia depade
        acamprosate campral
        disulfiram antabuse
        lofexidine lucemyra
      ].freeze

      # The one message every refusing entry point returns.
      REFUSAL = "MAT/MOUD ordering is not offered in this build"

      # Matching ignores case and every non-letter, so separators, padding and
      # doses ("buprenorphine_hcl", "Rx: naltrexone,50mg") cannot hide a name.
      def self.classify(text)
        return :unclassified unless text.is_a?(String)

        letters = text.downcase.gsub(/[^a-z]+/, "")
        return :unclassified if letters.empty?
        return :mat_moud if NAMES.any? { |name| letters.include?(name) }

        :not_mat_moud
      end

      # True only for :not_mat_moud — :mat_moud and :unclassified both refuse.
      def self.orderable?(text)
        classify(text) == :not_mat_moud
      end
    end
  end
end
