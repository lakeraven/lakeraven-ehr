# frozen_string_literal: true

module Lakeraven
  module EHR
    # Reads free text (a progress note) and answers whether it looks like
    # substance-use content (#906, slice of #522). It LABELS; it never
    # blocks a write.
    #
    #   :suspected      a vocabulary term, an ICD-10-CM F10–F19 code or a
    #                   Z71.4x / Z71.5x counselling code appears
    #   :not_suspected  readable text, with at least one letter or digit, in
    #                   which none of them appears
    #   :unclassified   anything else: not a String; a String that cannot be
    #                   read (an invalid byte sequence, or an encoding that
    #                   cannot be transcoded to UTF-8); text with no letter
    #                   or digit in it (blank, invisible characters only,
    #                   bare punctuation); or text that could not be matched
    #                   in time. Absence of data, or unreadable data, is
    #                   never evidence of safety.
    #
    # Before matching, the text is canonicalised in TWO forms, and it is
    # :suspected when either form matches. Both apply Unicode NFKC
    # (fullwidth and compatibility forms fold to plain letters and digits)
    # and read underscores and dash punctuation as spaces. Format characters
    # (soft hyphen, zero-width space, BOM) and non-whitespace control
    # characters (NUL, ESC, DEL, C1 controls) are REMOVED in the first form
    # and read as a SPACE in the second. So a soft hyphen or a NUL inside
    # "alcohol" still reads as the plain term (first form), and one used as
    # the only separator between words ("used<US>heroin") still separates
    # them (second form). A fullwidth "ａｌｃｏｈｏｌ", "substance_use" and
    # "F10_20" also read as the plain term or code. Readability is judged on
    # the first form; both forms hold the same letters and digits.
    #
    # classify never raises for a String: an unreadable String is
    # :unclassified, never clean.
    #
    # The vocabulary is NOT exhaustive: slang, misspellings, drug brand names
    # and other languages will get past it. :not_suspected is a statement
    # about THIS vocabulary, not a clinical safety claim. It also OVER-labels
    # by design: everyday words such as "wine", "beer", "rehab", "binge",
    # "drug" or "substance" label notes that are not about substance use
    # (a prescribed drug, a "drugstore", "substance of the session"), and
    # matching ignores negation ("denies alcohol use" is :suspected).
    # Over-labelling is the fail-closed direction.
    class SudContentSuspicion
      # Matched at a word START, so a term also matches its longer forms
      # (alcohol -> alcoholic, alcoholism; opioid -> opioids; drink -> drinks,
      # drinking; drug -> drugs; dependenc -> dependence, dependency). A
      # word-start match never fires inside a word: "independent" does not
      # match "dependenc".
      STEM_TERMS = %w[
        alcohol opioid opiate heroin fentanyl methamphetamine amphetamine
        cocaine cannabis marijuana ketamine kratom overdose opium
        buprenorphine suboxone subutex methadone naloxone narcan naltrexone
        vivitrol antabuse disulfiram
        oxycodone oxycontin hydrocodone hydromorphone dilaudid percocet
        morphine codeine tramadol narcotic
        benzodiazepin xanax klonopin valium ativan
        stimulant sedative inhalant hallucinogen mdma ecstasy
        drug substance dependenc
        withdrawal relapse drink drank drunk intoxicat sober sobriety detox
        addict polysubstance illicit binge blackout hungover hangover
        vodka liquor whiskey
      ].freeze

      # Phrases, also matched at a word start. Any Unicode whitespace or a
      # hyphen may separate their words ("substance-use", "substance use");
      # an underscore or any dash has become a space before matching.
      PHRASES = [
        "substance use", "substance abuse", "substance misuse",
        "drug use", "drug abuse", "drug misuse", "drug seeking",
        "recreational drug", "iv drug", "use disorder", "hung over",
        "twelve step"
      ].freeze

      # Short or ambiguous terms matched as WHOLE words only, so "meth" does
      # not match "methodology", "aa" does not match "AAA" and "got high"
      # does not match "got highly". Multi-word entries take the same
      # separators as PHRASES.
      WHOLE_WORD_TERMS = [
        "meth", "etoh", "sud", "suds", "oud", "aud", "ivdu", "ivda", "thc", "dui", "dwi",
        "uds", "aa", "lsd", "12 step", "12 steps", "got high", "benzo", "benzos",
        "rehab", "rehabs", "weed", "beer", "beers", "wine", "wines"
      ].freeze

      WORD_SEPARATOR = "[[:space:]\\-]+"

      # Every pattern carries a match timeout, so a pathological input cannot
      # hold the caller; a timeout is read as :unclassified.
      MATCH_TIMEOUT = 1.0

      def self.term_pattern(terms)
        terms.map { |term| term.split.map { |word| Regexp.escape(word) }.join(WORD_SEPARATOR) }.join("|")
      end
      private_class_method :term_pattern

      VOCABULARY = Regexp.new(
        "\\b(?:#{term_pattern(STEM_TERMS + PHRASES)})|\\b(?:#{term_pattern(WHOLE_WORD_TERMS)})\\b",
        Regexp::IGNORECASE,
        timeout: MATCH_TIMEOUT
      )

      # ICD-10-CM F10–F19 written in the text, dotted or undotted (the same
      # range Icd10CmSubstanceUseRange::SUBSTANCE_USE_CODE reads from a coded
      # field). F20 and on, and F3210, are outside it.
      SUBSTANCE_USE_CODE = Regexp.new(
        "\\bF1[0-9](?:\\.?[0-9A-Z]{1,4})?\\b",
        Regexp::IGNORECASE,
        timeout: MATCH_TIMEOUT
      )

      # The substance-use counselling codes outside F10–F19 that
      # Icd10CmSubstanceUseRange already reads as substance use, written in
      # the text, dotted or undotted.
      COUNSELLING_CODE = Regexp.new(
        "\\b(?:" + Icd10CmSubstanceUseRange::SUBSTANCE_USE_CODES_OUTSIDE_RANGE.map { |code|
          code.split(".").map { |part| Regexp.escape(part) }.join("\\.?")
        }.join("|") + ")\\b",
        Regexp::IGNORECASE,
        timeout: MATCH_TIMEOUT
      )

      PATTERNS = [ VOCABULARY, SUBSTANCE_USE_CODE, COUNSELLING_CODE ].freeze

      # A letter or a digit. Canonical text without one has no readable
      # content.
      READABLE_CONTENT = Regexp.new("[\\p{L}\\p{N}]", timeout: MATCH_TIMEOUT)

      # Format characters (soft hyphen, zero-width space and joiners, BOM,
      # bidi controls) and the control characters that are not whitespace
      # (NUL, U+0001-U+0008, U+000E-U+001F, U+007F, U+0080-U+009F except
      # U+0085). Each is removed in one canonical form, so "alco<NUL>hol"
      # reads as "alcohol", and read as a space in the other, so
      # "used<US>heroin" reads as "used heroin". Whitespace controls (tab,
      # line feed, vertical tab, form feed, carriage return, U+0085) are kept
      # in both forms and always separate words.
      FORMAT_CHARACTERS = /[\p{Cf}[^\P{Cc}[:space:]]]/

      # Read as a word separator before matching: underscore and all dash
      # punctuation (hyphen, non-breaking hyphen, en and em dash, ...).
      SEPARATOR_CHARACTERS = /[_\p{Pd}]/

      def self.classify(text)
        return :unclassified unless text.is_a?(String)

        readable = readable_utf8(text)
        return :unclassified if readable.nil?

        removed = canonicalise(readable, format_replacement: "")
        return :unclassified unless READABLE_CONTENT.match?(removed)

        spaced = canonicalise(readable, format_replacement: " ")
        return :suspected if [ removed, spaced ].any? { |form| suspected_form?(form) }

        :not_suspected
      # A match that times out (Regexp::TimeoutError is a RegexpError), or
      # text whose characters do not survive canonicalisation, has not been
      # read. Unread text is never clean, and classify must not raise for a
      # String: callers label on its answer and a note must never be blocked
      # by it.
      rescue RegexpError, EncodingError
        :unclassified
      end

      # The text as valid UTF-8, or nil when it cannot be read. Checked
      # rather than rescued where possible: an invalid byte sequence or a
      # non-ASCII-compatible encoding (UTF-16, UTF-32) is refused up front,
      # so a regex match never sees it. The only rescue is the transcode of
      # an otherwise-valid String in another encoding (Latin-1, binary, ...),
      # which raises EncodingError when a character has no UTF-8 form.
      def self.readable_utf8(text)
        return nil unless text.encoding.ascii_compatible? && text.valid_encoding?
        return text if text.encoding == Encoding::UTF_8

        text.encode(Encoding::UTF_8)
      rescue EncodingError
        nil
      end
      private_class_method :readable_utf8

      # NFKC, then format and non-whitespace control characters replaced by
      # format_replacement ("" for the removed form, " " for the spaced
      # form) and separators spaced, so a term is matched on what a reader
      # sees rather than how it is keyed.
      def self.canonicalise(text, format_replacement:)
        text.unicode_normalize(:nfkc).gsub(FORMAT_CHARACTERS, format_replacement).gsub(SEPARATOR_CHARACTERS, " ")
      end
      private_class_method :canonicalise

      def self.suspected_form?(canonical)
        PATTERNS.any? { |pattern| pattern.match?(canonical) }
      end
      private_class_method :suspected_form?
    end
  end
end
