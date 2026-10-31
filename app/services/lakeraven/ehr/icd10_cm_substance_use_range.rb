# frozen_string_literal: true

module Lakeraven
  module EHR
    # Discriminator the #560 write seam uses: ICD-10-CM F10–F19
    # (psychoactive substance use).
    #
    # This is not a Part 2 classifier. It does not read SNOMED,
    # medications, labs, free text, or progress notes. A payload it
    # cannot read is :unclassified. Writers into a shared RPMS file
    # treat that as a refusal — an unreadable code is not evidence the
    # code is safe to put there, and those files have no per-record
    # sensitivity flag to set later.
    class Icd10CmSubstanceUseRange
      ICD10_SYSTEMS = %w[
        http://hl7.org/fhir/sid/icd-10-cm
        http://hl7.org/fhir/sid/icd-10
        icd10
        icd-10
        icd-10-cm
      ].freeze

      # Letter, two characters, optional dot and up to four more.
      # Distinguishes E11.9 from a SNOMED numeral. Not an ICD-10 parser.
      ICD10_CODE = /\A[A-Z][0-9][0-9A-Z](?:\.[0-9A-Z]{1,4})?\z/

      # F10–F19. The rest of ICD-10-CM chapter 5 (F20 and on) is outside it.
      SUBSTANCE_USE_CODE = /\AF1[0-9](?:\.[0-9A-Z]{1,4})?\z/

      # Substance-use codes OUTSIDE F10–F19. A gate seat found Z71.41
      # "Alcohol abuse counseling and surveillance of alcoholic" reaching the
      # shared problem list because it is a valid ICD code outside the range.
      # Verified against the ICD-10-CM FY2026 set rather than guessed:
      #   Z71.4  / Z71.41 / Z71.42   alcohol abuse counseling and surveillance
      #   Z71.5  / Z71.51 / Z71.52   drug abuse counseling and surveillance
      # F55 (abuse of NON-psychoactive substances — antacids, laxatives,
      # vitamins) is deliberately EXCLUDED: it is not alcohol or drug abuse
      # and so not a Part 2 record.
      #
      # NOT EXHAUSTIVE, and the code must not pretend otherwise. Codes
      # carrying substance-use meaning exist elsewhere in ICD-10-CM
      # (obstetric, poisoning and history-of categories among them). This set
      # is what has been sourced, which is why :not_sud remains a statement
      # about THIS discriminator and not a clinical safety claim.
      SUBSTANCE_USE_CODES_OUTSIDE_RANGE = %w[
        Z71.4 Z71.41 Z71.42
        Z71.5 Z71.51 Z71.52
      ].freeze

      # Classifies EVERY code-bearing field and the MOST RESTRICTIVE answer
      # wins. A gate seat found that a safe-looking :code shadowed an F10–F19
      # :icd_code, because the old extract stopped at the first key it found —
      # `{code: "E11.9", icd_code: "F11.20"}` was written to the shared
      # problem list. Precedence between fields is not a safety property;
      # on an irreversible write every candidate has to be read.
      def self.classify(problem)
        codes = extract_codes(problem)
        return :unclassified if codes.empty?

        system = extract_system(problem)
        results = codes.map { |code| classify_one(code, system) }

        return :sud if results.include?(:sud)
        return :unclassified if results.include?(:unclassified)

        :not_sud
      end

      def self.classify_one(code, system)
        return :unclassified if code.blank?
        return :unclassified unless icd10_cm?(system)

        normalized = code.to_s.strip.upcase
        return :unclassified unless ICD10_CODE.match?(normalized)
        return :sud if SUBSTANCE_USE_CODE.match?(normalized)
        return :sud if SUBSTANCE_USE_CODES_OUTSIDE_RANGE.include?(normalized)

        :not_sud
      end
      private_class_method :classify_one

      def self.normalized_code(problem)
        extract_codes(problem).first.to_s.strip.upcase.presence
      end

      CODE_KEYS = %i[code icd_code].freeze

      # EVERY code-bearing field, not the first one present.
      def self.extract_codes(problem)
        return [] unless problem.is_a?(Hash)

        CODE_KEYS.filter_map { |key| value(problem, key).presence }
      end
      private_class_method :extract_codes

      def self.extract_system(problem)
        return nil unless problem.is_a?(Hash)

        value(problem, :code_system, :system)
      end
      private_class_method :extract_system

      def self.value(problem, *keys)
        keys.each do |key|
          return problem[key] if problem.key?(key)

          string_key = key.to_s
          return problem[string_key] if problem.key?(string_key)
        end
        nil
      end
      private_class_method :value

      def self.icd10_cm?(system)
        text = system.to_s.strip
        return true if text.empty?

        ICD10_SYSTEMS.include?(text.downcase)
      end
      private_class_method :icd10_cm?
    end
  end
end
