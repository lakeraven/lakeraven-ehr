# frozen_string_literal: true

module Lakeraven
  module EHR
    # Reads free text (a progress note) and answers whether it looks like
    # substance-use content (#906, slice of #522). It LABELS; it never
    # blocks a write.
    #
    #   :suspected      a vocabulary term or an ICD-10-CM F10–F19 code appears
    #   :not_suspected  a String in which none of them appears
    #   :unclassified   input that is not a String — not evidence of safety
    #
    # The vocabulary is NOT exhaustive: slang, misspellings, drug brand names
    # and other languages will get past it. :not_suspected is a statement
    # about THIS vocabulary, not a clinical safety claim. Matching ignores
    # negation on purpose ("denies alcohol use" is :suspected): over-labelling
    # is the fail-closed direction.
    class SudContentSuspicion
      # Matched at a word START, so a term also matches its longer forms
      # (alcohol -> alcoholic, alcoholism; opioid -> opioids; drink -> drinks,
      # drinking).
      STEM_TERMS = %w[
        alcohol opioid opiate heroin fentanyl methamphetamine cocaine
        cannabis marijuana overdose buprenorphine suboxone methadone naloxone
        narcan naltrexone withdrawal relapse drink drunk intoxicat sobriety
        detox addict
      ].freeze

      # Phrases, also matched at a word start, with any whitespace between
      # their words.
      PHRASES = [
        "substance use", "substance abuse", "drug use", "drug abuse"
      ].freeze

      # Short or ambiguous terms matched as WHOLE words only, so "meth" does
      # not match "methodology" or "method".
      WHOLE_WORD_TERMS = %w[meth etoh].freeze

      STEM_PATTERN = (STEM_TERMS + PHRASES).map { |term|
        term.split.map { |word| Regexp.escape(word) }.join('\s+')
      }.join("|")
      WHOLE_WORD_PATTERN = WHOLE_WORD_TERMS.map { |term| Regexp.escape(term) }.join("|")

      VOCABULARY = /\b(?:(?:#{STEM_PATTERN})|(?:#{WHOLE_WORD_PATTERN})\b)/i

      # ICD-10-CM F10–F19 written in the text (the same range
      # Icd10CmSubstanceUseRange::SUBSTANCE_USE_CODE reads from a coded
      # field). F20 and on are outside it.
      SUBSTANCE_USE_CODE = /\bF1[0-9](?:\.[0-9A-Z]{1,4})?\b/i

      def self.classify(text)
        return :unclassified unless text.is_a?(String)
        return :not_suspected if text.blank?
        return :suspected if VOCABULARY.match?(text) || SUBSTANCE_USE_CODE.match?(text)

        :not_suspected
      end
    end
  end
end
