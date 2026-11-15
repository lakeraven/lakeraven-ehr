# frozen_string_literal: true

module Lakeraven
  module EHR
    # Discriminator every ordering entry point uses for #904: the December
    # build (MH-only clinic, Part 2 posture of #522) offers no MAT/MOUD
    # ordering pathway.
    #
    # This is not a Part 2 classifier. It reads medication TEXT only — it
    # does not read RxNorm, NDC or any other code, nor diagnoses, labs or
    # notes. A sourced RxNorm MAT/MOUD value set is follow-up work. Text it
    # cannot read is :unclassified, and callers refuse that: unreadable text
    # is not evidence the order is safe to place.
    #
    # Reading: the text must be a String in an ASCII-compatible encoding that
    # is (or converts to) valid UTF-8.
    # It is NFKC-normalised (so fullwidth and other compatibility forms become
    # ASCII) and downcased. If any letter outside a-z remains — an accented
    # letter, a Cyrillic look-alike, another script — the text is
    # :unclassified: these lists are ASCII, so a non-ASCII letter could be
    # hiding a name ("methаdone" with a Cyrillic а) and is not evidence of
    # safety.
    class MatMoudMedication
      # Long, unambiguous stems of generic and brand names of medications for
      # opioid and alcohol use disorder (buprenorphine, methadone, naltrexone,
      # acamprosate, disulfiram, lofexidine, levomethadyl). Matched as
      # SUBSTRINGS of the text with every non-letter removed, so separators,
      # padding and doses ("buprenorphine_hcl", "Rx: naltrexone,50mg") cannot
      # hide a name, and stems catch spelling variants ("buprenorfina",
      # "metadona", "Suboxon"). Naloxone ALONE is deliberately EXCLUDED: it is
      # overdose reversal, not MOUD. Buprenorphine/naloxone combinations are
      # caught by their buprenorphine or brand name.
      STEMS = %w[
        buprenorph buprenorf methadon metadon naltrexon acampros disulfir lofexid
        levomethadyl
        suboxon subutex zubsolv bunavail sublocade brixadi probuphin butrans
        belbuca buprenex cassipa
        dolophin methadose diskets
        vivitrol
        campral
        antabuse
        lucemyra
      ].freeze

      # Short names and abbreviations that occur inside ordinary words
      # ("previa", "abbreviated", "Ensure via" all contain "revia"). Matched
      # only as WHOLE tokens of the normalised text split on non-letters.
      # "bup" as a whole word does not match "Bupropion".
      WORDS = %w[revia depade trexan laam bup bupe].freeze

      # NOT EXHAUSTIVE, and the code must not pretend otherwise. Other brands,
      # misspellings and compounded products exist. :not_mat_moud is a
      # statement about THESE lists and not a clinical safety claim.

      # The one message every refusing entry point returns.
      REFUSAL = "MAT/MOUD ordering is not offered in this build"

      def self.classify(text)
        normalised = readable_text(text)
        return :unclassified if normalised.nil?
        return :unclassified if normalised.match?(/[^\P{L}a-z]/)
        return :unclassified unless normalised.match?(/[a-z]/)

        letters = normalised.gsub(/[^a-z]+/, "")
        return :mat_moud if STEMS.any? { |stem| letters.include?(stem) }

        tokens = normalised.split(/[^a-z]+/)
        return :mat_moud if tokens.intersect?(WORDS)

        :not_mat_moud
      end

      # True only for :not_mat_moud — :mat_moud and :unclassified both refuse.
      def self.orderable?(text)
        classify(text) == :not_mat_moud
      end

      # NFKC-normalised, downcased UTF-8 text, or nil when the value is not a
      # String or cannot be read as UTF-8. A string in an encoding that is not
      # ASCII-compatible (UTF-16, UTF-32) is not UTF-8 text even when it could
      # be transcoded, so it is not read either.
      def self.readable_text(text)
        return nil unless text.is_a?(String)
        return nil unless text.encoding.ascii_compatible?

        utf8 = begin
          text.encode("UTF-8")
        rescue EncodingError
          return nil
        end
        return nil unless utf8.valid_encoding?

        utf8.unicode_normalize(:nfkc).downcase
      rescue EncodingError, ArgumentError
        nil
      end
      private_class_method :readable_text
    end
  end
end
