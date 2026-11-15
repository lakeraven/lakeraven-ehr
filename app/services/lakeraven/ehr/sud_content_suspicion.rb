# frozen_string_literal: true

module Lakeraven
  module EHR
    # Reads free text (a progress note) and answers whether it looks like
    # substance-use content (#906, slice of #522). It LABELS; it never
    # blocks a write.
    #
    #   :suspected      a vocabulary term, an ICD-10-CM F10–F19 code or a
    #                   Z71.4x / Z71.5x counselling code appears
    #   :not_suspected  readable, non-blank text in which none of them appears
    #   :unclassified   anything else: not a String, blank, or a String that
    #                   cannot be read (an invalid byte sequence, or an
    #                   encoding that cannot be transcoded to UTF-8). Absence
    #                   of data, or unreadable data, is never evidence of
    #                   safety.
    #
    # classify never raises for a String: an unreadable String is
    # :unclassified, never clean.
    #
    # The vocabulary is NOT exhaustive: slang, misspellings, drug brand names
    # and other languages will get past it. :not_suspected is a statement
    # about THIS vocabulary, not a clinical safety claim. It also OVER-labels
    # by design: everyday words such as "wine", "beer", "rehab" or "binge"
    # label notes that are not about substance use, and matching ignores
    # negation ("denies alcohol use" is :suspected). Over-labelling is the
    # fail-closed direction.
    class SudContentSuspicion
      # Matched at a word START, so a term also matches its longer forms
      # (alcohol -> alcoholic, alcoholism; opioid -> opioids; drink -> drinks,
      # drinking; narcotic -> narcotics).
      STEM_TERMS = %w[
        alcohol opioid opiate heroin fentanyl methamphetamine amphetamine
        cocaine cannabis marijuana ketamine kratom overdose
        buprenorphine suboxone subutex methadone naloxone narcan naltrexone
        vivitrol antabuse disulfiram
        oxycodone oxycontin hydrocodone percocet morphine codeine narcotic
        benzodiazepin xanax
        withdrawal relapse drink drank drunk intoxicat sober sobriety detox
        addict polysubstance illicit binge blackout hungover vodka liquor
      ].freeze

      # Phrases, also matched at a word start. Any Unicode whitespace or a
      # hyphen may separate their words ("substance-use", "substance use").
      PHRASES = [
        "substance use", "substance abuse", "substance misuse",
        "drug use", "drug abuse", "drug misuse", "drug seeking",
        "recreational drug"
      ].freeze

      # Short or ambiguous terms matched as WHOLE words only, so "meth" does
      # not match "methodology" and "aa" does not match "AAA". Multi-word
      # entries take the same separators as PHRASES.
      WHOLE_WORD_TERMS = [
        "meth", "etoh", "sud", "oud", "aud", "ivdu", "ivda", "thc", "dui", "dwi",
        "uds", "aa", "12 step", "12 steps", "benzo", "benzos", "rehab", "rehabs",
        "weed", "beer", "beers", "wine", "wines"
      ].freeze

      WORD_SEPARATOR = "[[:space:]\\-]+"

      def self.term_pattern(terms)
        terms.map { |term| term.split.map { |word| Regexp.escape(word) }.join(WORD_SEPARATOR) }.join("|")
      end
      private_class_method :term_pattern

      VOCABULARY = /
        \b(?:#{term_pattern(STEM_TERMS + PHRASES)})
        |
        \b(?:#{term_pattern(WHOLE_WORD_TERMS)})\b
      /ix

      # ICD-10-CM F10–F19 written in the text, dotted or undotted (the same
      # range Icd10CmSubstanceUseRange::SUBSTANCE_USE_CODE reads from a coded
      # field). F20 and on, and F3210, are outside it.
      SUBSTANCE_USE_CODE = /\bF1[0-9](?:\.?[0-9A-Z]{1,4})?\b/i

      # The substance-use counselling codes outside F10–F19 that
      # Icd10CmSubstanceUseRange already reads as substance use, written in
      # the text, dotted or undotted.
      COUNSELLING_CODE = Regexp.new(
        "\\b(?:" + Icd10CmSubstanceUseRange::SUBSTANCE_USE_CODES_OUTSIDE_RANGE.map { |code|
          code.split(".").map { |part| Regexp.escape(part) }.join("\\.?")
        }.join("|") + ")\\b",
        Regexp::IGNORECASE
      )

      def self.classify(text)
        return :unclassified unless text.is_a?(String)

        readable = readable_utf8(text)
        return :unclassified if readable.nil? || readable.blank?
        return :suspected if [ VOCABULARY, SUBSTANCE_USE_CODE, COUNSELLING_CODE ].any? { |pattern| pattern.match?(readable) }

        :not_suspected
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
    end
  end
end
