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

      # F10–F19 only. The rest of ICD-10-CM chapter 5 (F20 and on) is
      # outside this range.
      SUBSTANCE_USE_CODE = /\AF1[0-9](?:\.[0-9A-Z]{1,4})?\z/

      def self.classify(problem)
        code, system = extract(problem)
        return :unclassified if code.blank?
        return :unclassified unless icd10_cm?(system)

        normalized = code.to_s.strip.upcase
        return :unclassified unless ICD10_CODE.match?(normalized)

        SUBSTANCE_USE_CODE.match?(normalized) ? :sud : :not_sud
      end

      def self.normalized_code(problem)
        code, = extract(problem)
        code.to_s.strip.upcase.presence
      end

      def self.extract(problem)
        return [ nil, nil ] unless problem.is_a?(Hash)

        [ value(problem, :code) || value(problem, :icd_code), value(problem, :code_system, :system) ]
      end
      private_class_method :extract

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
