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
    # - the micro sign (U+00B5) and Greek mu (U+03BC) are read as "mc" ONLY
    #   as a dose unit: preceded by a digit, or by whitespace that follows a
    #   digit, and immediately followed by g, G, l or L ("50µg", "50 µg",
    #   "100 μL"). Anywhere else the text is :unclassified — read as "mc"
    #   inside a word it would split a name ("methaµdone");
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

      # The refusal for an order: the medication text is read first, then the
      # sig. The sig is free text the NewRx sends to the pharmacy as SigText
      # and Directions, so it is read with the same rule — except that a nil
      # sig, or a String sig of only spaces, tabs and line breaks, is allowed (no
      # sig names nothing). The medication itself is never allowed blank.
      def self.refusal_for_order(medication_text, sig_text)
        refusal = refusal_for(medication_text)
        return refusal if refusal
        return nil if sig_text.nil?
        return nil if blank_string?(sig_text)

        refusal_for(sig_text)
      end

      # Returned by approve_change for every change id: nothing was ordered,
      # so REFUSAL would mislead; this names the pharmacy change not approved.
      CHANGE_APPROVAL_REFUSAL = "Approving a pharmacy change is not offered in this build: " \
                                "the proposed medication cannot be shown not to be MAT/MOUD"

      DISALLOWED_CONTROL = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
      MICRO_SIGNS = [ "\u00B5", "\u03BC" ].freeze
      DOSE_UNIT_AFTER_MICRO = /\A[gGlL]/
      private_constant :DISALLOWED_CONTROL, :MICRO_SIGNS, :DOSE_UNIT_AFTER_MICRO

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
        chars = utf8.each_char.to_a
        chars.each_with_index do |char, index|
          if char.ascii_only?
            read << char
          elsif MICRO_SIGNS.include?(char)
            return nil unless micro_dose_unit?(chars, index)

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

      # A micro sign at chars[index] is a dose unit when the next character is
      # g/G/l/L and the character before it is a digit, or is whitespace that
      # itself follows a digit.
      def self.micro_dose_unit?(chars, index)
        return false unless chars[index + 1]&.match?(DOSE_UNIT_AFTER_MICRO)

        before = index - 1
        before -= 1 if before >= 0 && chars[before].match?(/\A\s\z/)
        before >= 0 && chars[before].match?(/\A[0-9]\z/)
      end
      private_class_method :micro_dose_unit?

      # True for a String that is empty after stripping. Text that cannot even
      # be stripped (invalid bytes) is not blank.
      # Blank means only the whitespace the reading rule accepts (space, tab,
      # LF, CR). String#strip also drops NUL, VT and FF, which the rule
      # treats as unreadable, so it must not decide blankness.
      def self.blank_string?(value)
        value.is_a?(String) && value.match?(/\A[ \t\r\n]*\z/)
      rescue EncodingError, ArgumentError
        false
      end
      private_class_method :blank_string?
    end
  end
end
