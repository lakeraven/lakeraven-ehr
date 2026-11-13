# frozen_string_literal: true

module Lakeraven
  module EHR
    # The patient's languages as the front desk records them (rpms-ux S-REG-10):
    # a new LANGUAGES ENTRY DATE (#9000001.86) entry each time.
    #
    # The rules are BPRM's (PatientProfile) and AG's (its window's triggers,
    # PLNG^AGGPTRGO): English spoken needs a proficiency, and "not at all" does
    # not fit it; a primary language other than English needs the interpreter
    # answer; an other language may not repeat the primary or itself. A
    # preferred language that is neither the primary nor an other language is
    # a warning the clerk may accept.
    class LanguageEntry
      include ActiveModel::Model
      include ActiveModel::Attributes
      include SiteRequiredFields

      # #9000001.86 .03 INTREPRETER REQUIRED and .06 ENGLISH PROFICIENCY codes.
      INTERPRETER = { "Y" => "Yes", "N" => "No", "U" => "Unknown" }.freeze
      PROFICIENCY = { "VW" => "Very well", "W" => "Well", "NW" => "Not well", "NA" => "Not at all" }.freeze

      attribute :primary_ien, :integer
      attribute :preferred_ien, :integer
      attribute :interpreter, :string
      attribute :proficiency, :string
      attribute :preferred_confirmed, :boolean, default: false
      attr_accessor :english_ien
      attr_writer :others

      validates :primary_ien, presence: { message: "is required" }
      # A site may make the preferred language mandatory in RPMS (#980): AG
      # checks PREFERRED LANGUAGE by name ($$ALTREQ^AGFLDREQ, AGAPIPAT). The
      # primary language is required on every site, as AG's window asks it.
      site_required preferred_ien: [ "9000001", "PREFERRED LANGUAGE" ]

      NAMES = { primary_ien: "Primary language", preferred_ien: "Preferred language" }.freeze

      def self.human_attribute_name(attribute, options = {})
        NAMES.fetch(attribute.to_sym) { super }
      end
      validates :interpreter, inclusion: { in: INTERPRETER.keys }, allow_blank: true
      validates :proficiency, inclusion: { in: PROFICIENCY.keys }, allow_blank: true
      validate :english_proficiency
      validate :interpreter_answer
      validate :other_languages_distinct

      # The entry RPMS has now (a RpmsRpc::PatientProfile languages hash).
      def self.from_rpms(languages)
        languages = languages.to_h
        new(primary_ien: languages.dig(:primary, :ien), preferred_ien: languages.dig(:preferred, :ien),
            interpreter: languages[:interpreter], proficiency: languages[:proficiency],
            others: Array(languages[:others]).map { |other| other[:ien] })
      end

      def others = Array(@others).map(&:to_i).reject(&:zero?)

      def speaks_english? = english_ien.present? && (primary_ien == english_ien || others.include?(english_ien))

      # S-REG-10.5: a warning, not a refusal.
      def preferred_unlisted?
        preferred_ien.present? && ![ primary_ien, *others ].include?(preferred_ien)
      end

      def needs_preferred_confirmation? = preferred_unlisted? && !preferred_confirmed

      # What RpmsRpc::PatientProfile.record_languages takes. No interpreter
      # answer is sent for an English speaker: AG's window turns it off.
      def record_attrs
        { primary: primary_ien, preferred: preferred_ien, proficiency: proficiency.presence,
          interpreter: (primary_ien == english_ien ? nil : interpreter.presence), others: others, english_ien: english_ien }
      end

      private

      def english_proficiency
        return unless speaks_english?

        if proficiency.blank?
          errors.add(:proficiency, "is needed when the patient speaks English")
        elsif proficiency == "NA"
          errors.add(:proficiency, "cannot be “Not at all” when the patient speaks English")
        end
      end

      def interpreter_answer
        return if primary_ien.blank? || english_ien.blank? || primary_ien == english_ien
        return if interpreter.present?

        errors.add(:interpreter, "must be answered when the primary language is not English")
      end

      def other_languages_distinct
        list = Array(@others).map(&:to_i).reject(&:zero?)
        if primary_ien.present? && list.include?(primary_ien)
          errors.add(:others, "cannot include the primary language")
        elsif list.uniq.size != list.size
          errors.add(:others, "cannot list a language twice")
        end
      end
    end
  end
end
