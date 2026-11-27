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
    # Before matching, the text goes through ONE normalisation step:
    #   1. Unicode NFKC (fullwidth and compatibility forms fold to plain
    #      letters and digits, so "ａｌｃｏｈｏｌ" reads as "alcohol").
    #   2. Every maximal run of invisible code points becomes ONE sentinel:
    #      Default_Ignorable_Code_Point (soft hyphen, zero-width space and
    #      joiners, BOM, combining grapheme joiner, Hangul fillers, variation
    #      selectors, tags), every Cf, every Cc (NUL, ESC, DEL, C1 controls
    #      and the whitespace controls too: tab, line feed, vertical tab,
    #      form feed, carriage return, U+0085) and private-use characters
    #      (Co, so the sentinel itself cannot arrive as input). Whitespace
    #      controls are read like the other invisible characters: removed
    #      inside a term, a boundary between words.
    #   3. Underscores and dash punctuation read as spaces ("substance_use",
    #      "F10_20").
    # Every pattern allows the sentinel between any two characters of a
    # term or code, and a phrase also takes it as a word separator. The
    # sentinel is not a word character, so a word boundary holds next to
    # it. Each invisible character is therefore read per position: removed
    # inside a term ("alco<NUL>hol" is alcohol) and a boundary between words
    # ("used<US>heroin" starts a word at "heroin"), in the same text.
    # Readability is judged on the normalised text; the sentinel is not a
    # letter or digit. Matching only decides the label: classify answers a
    # Symbol and never returns, logs, stores or keeps the normalised text.
    #
    # classify never raises for a String: an unreadable String, or one whose
    # normalisation or matching fails, is :unclassified, never clean.
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

      # Stands for a run of invisible code points in the normalised text. It
      # is private use (Co), so any copy of it in the input is itself
      # invisible and replaced; and it is not a word character, so \b holds
      # next to it.
      SENTINEL = "\u{E000}"
      OPTIONAL_SENTINEL = "#{SENTINEL}?"

      WORD_SEPARATOR = "[[:space:]\\-#{SENTINEL}]+"

      # Every pattern carries a match timeout, so a pathological input cannot
      # hold the caller; a timeout is read as :unclassified.
      MATCH_TIMEOUT = 1.0

      # Regex fragments joined so that one sentinel may stand between any two
      # of them: the one place an invisible character inside a term or code
      # is allowed for. Each fragment matches a single character, so the
      # pattern stays linear.
      def self.spread(fragments)
        fragments.join(OPTIONAL_SENTINEL)
      end
      private_class_method :spread

      def self.term_pattern(terms)
        terms.map { |term|
          term.split.map { |word| spread(word.chars.map { |char| Regexp.escape(char) }) }.join(WORD_SEPARATOR)
        }.join("|")
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
        "\\b#{spread(%w[F 1 [0-9]])}" \
        "(?:#{spread([ '', '\\.?', '[0-9A-Z]' ])}(?:#{OPTIONAL_SENTINEL}[0-9A-Z]){0,3})?\\b",
        Regexp::IGNORECASE,
        timeout: MATCH_TIMEOUT
      )

      # The substance-use counselling codes outside F10–F19 that
      # Icd10CmSubstanceUseRange already reads as substance use, written in
      # the text, dotted or undotted.
      COUNSELLING_CODE = Regexp.new(
        "\\b(?:" + Icd10CmSubstanceUseRange::SUBSTANCE_USE_CODES_OUTSIDE_RANGE.map { |code|
          spread(code.chars.map { |char| char == "." ? "\\.?" : Regexp.escape(char) })
        }.join("|") + ")\\b",
        Regexp::IGNORECASE,
        timeout: MATCH_TIMEOUT
      )

      PATTERNS = [ VOCABULARY, SUBSTANCE_USE_CODE, COUNSELLING_CODE ].freeze

      # A letter or a digit. Normalised text without one has no readable
      # content.
      READABLE_CONTENT = Regexp.new("[\\p{L}\\p{N}]", timeout: MATCH_TIMEOUT)

      # Invisible code points, each maximal run replaced by one SENTINEL:
      # Default_Ignorable_Code_Point, format characters (Cf), private-use
      # characters (Co, which holds the sentinel) and every control
      # character (Cc: U+0000-U+001F, U+007F-U+009F). Whitespace controls
      # (tab, line feed, vertical tab, form feed, carriage return, U+0085)
      # are read like the other invisible characters: removed inside a term,
      # a boundary between words.
      INVISIBLE_RUN = Regexp.new(
        "[\\p{Default_Ignorable_Code_Point}\\p{Cf}\\p{Co}\\p{Cc}]+",
        timeout: MATCH_TIMEOUT
      )

      # Read as a word separator before matching: underscore and all dash
      # punctuation (hyphen, non-breaking hyphen, en and em dash, ...).
      SEPARATOR_CHARACTERS = /[_\p{Pd}]/

      def self.classify(text)
        return :unclassified unless text.is_a?(String)

        readable = readable_utf8(text)
        return :unclassified if readable.nil?

        normalised = normalise(readable)
        return :unclassified unless READABLE_CONTENT.match?(normalised)
        return :suspected if PATTERNS.any? { |pattern| pattern.match?(normalised) }

        :not_suspected
      # Any error while reading, normalising or matching (a match timeout is
      # a RegexpError; a failed normalisation can raise ArgumentError or an
      # EncodingError) means the text has not been read, and unread text is
      # never clean. :unclassified text is labelled by
      # ProgressNoteService#label_part2 and read as Part 2 by Part2Posture.
      # classify must not raise for a String: callers label on its answer
      # and a note must never be blocked by it.
      rescue StandardError
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

      # The one normalisation step: NFKC, then each run of invisible code
      # points as one sentinel, then separators as spaces, so a term is
      # matched on what a reader sees rather than how it is keyed. Used only
      # to decide the label; never kept.
      def self.normalise(text)
        text.unicode_normalize(:nfkc).gsub(INVISIBLE_RUN, SENTINEL).gsub(SEPARATOR_CHARACTERS, " ")
      end
      private_class_method :normalise
    end
  end
end
