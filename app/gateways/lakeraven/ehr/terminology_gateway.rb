# frozen_string_literal: true

require "rpms_rpc/api/terminology"

module Lakeraven
  module EHR
    # SNOMED CT from RPMS's own terminology package, IHS Standard
    # Terminology (BSTS), through RpmsRpc::Terminology (ADR 0018: RPMS is
    # the first source). Every read answers from the server's local BSTS
    # copy; none reaches out to a remote terminology service.
    #
    # A refused or failed read raises the gem's error, so a page says RPMS
    # did not answer rather than showing an empty list. An empty list means
    # BSTS holds no match.
    class TerminologyGateway
      SEARCH_LIMIT = 25
      WORD_LIMIT = 10

      # The words BSTS's terms hold that start with +text+'s last word, for
      # the "words that match" hint beside a search.
      def self.words_starting(text, via: default_provider)
        word = text.to_s.split.last.to_s
        return [] if word.empty? || word.include?("^")

        via.type_ahead(word, max: WORD_LIMIT)
      end

      # SNOMED CT concepts whose terms match +text+, each with its ICD-10-CM
      # codes: [{ concept_id:, dts_id:, term:, preferred_term:, fsn:, icd: [] }].
      def self.search(text, via: default_provider)
        via.search(text, max: SEARCH_LIMIT)
      end

      # One concept's detail by its BSTS concept number (+dts_id+ from a
      # search), or nil when BSTS has no such concept.
      def self.concept(dts_id, via: default_provider)
        via.concept(dts_id)
      end

      # Text BSTS can be asked about: a search splits on "|" and "^".
      def self.searchable?(text)
        value = text.to_s.strip
        !value.empty? && value.length <= 80 && !value.match?(/[|^]/)
      end

      def self.default_provider
        ::RpmsRpc::Terminology
      end
    end
  end
end
