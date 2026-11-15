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
    # is (or converts to) valid UTF-8, and is read character by character:
    # - an ASCII control character other than tab, LF and CR makes the text
    #   :unclassified;
    # - the micro sign (U+00B5) and Greek mu (U+03BC) are read as "mc" (dose
    #   units such as "50 µg");
    # - any other non-ASCII character is accepted only when its NFKC form is
    #   exactly one printable ASCII character (fullwidth and mathematical
    #   letters), and is read as that character. Anything else — a symbol,
    #   emoji, trademark sign, dash, soft hyphen, zero-width space, combining
    #   mark, accented letter, Cyrillic look-alike or other script — makes the
    #   text :unclassified. These lists are ASCII, so a character that does
    #   not read as one ASCII character could hide or split a name
    #   ("methаdone" with a Cyrillic а, "re<soft hyphen>via", "Revia™" read
    #   as "reviatm") and is not evidence of safety.
    # The text read is then downcased, pure ASCII.
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
        levomethadyl orlaam metadol
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

      # Returned instead of REFUSAL for :unclassified text, so staff can tell
      # "we do not offer this" from "we could not read what you typed".
      UNREADABLE = "Medication text could not be read, so it cannot be shown not to be MAT/MOUD; " \
                   "retype it in plain letters"

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

      # The message an ordering entry point returns when it refuses text:
      # nil when the text is orderable, REFUSAL for a MAT/MOUD name, and
      # UNREADABLE for text that could not be read.
      def self.refusal_for(text)
        case classify(text)
        when :not_mat_moud then nil
        when :mat_moud then REFUSAL
        else UNREADABLE
        end
      end

      DISALLOWED_CONTROL = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
      MICRO_SIGNS = [ "\u00B5", "\u03BC" ].freeze
      private_constant :DISALLOWED_CONTROL, :MICRO_SIGNS

      # Downcased pure-ASCII text read as described above, or nil when the
      # value is not a String, cannot be read as UTF-8, or contains a
      # character that does not read as one printable ASCII character. A
      # string in an encoding that is not ASCII-compatible (UTF-16, UTF-32)
      # is not UTF-8 text even when it could be transcoded, so it is not read
      # either.
      def self.readable_text(text)
        return nil unless text.is_a?(String)
        return nil unless text.encoding.ascii_compatible?

        utf8 = begin
          text.encode("UTF-8")
        rescue EncodingError
          return nil
        end
        return nil unless utf8.valid_encoding?
        return nil if utf8.match?(DISALLOWED_CONTROL)

        read = +""
        utf8.each_char do |char|
          if char.ascii_only?
            read << char
          elsif MICRO_SIGNS.include?(char)
            read << "mc"
          else
            ascii = char.unicode_normalize(:nfkc)
            return nil unless ascii.match?(/\A[\x20-\x7E]\z/)

            read << ascii
          end
        end
        read.downcase
      rescue EncodingError, ArgumentError
        nil
      end
      private_class_method :readable_text
    end
  end
end
