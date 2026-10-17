# frozen_string_literal: true

module Lakeraven
  module EHR
    # Display fields for the persistent banner. Values are already authorized
    # and already filtered; this object does not fetch.
    class PatientBanner
      SEX_LABELS = { "F" => "Female", "M" => "Male", "U" => "Unknown" }.freeze
      MISSING = "—"

      attr_reader :demographics, :allergies

      def self.empty
        new(empty: true, show_clear: false, demographics: nil, allergies: nil)
      end

      # Context is open, but nothing clinical may be shown.
      def self.closed
        new(empty: false, show_clear: true, demographics: nil,
            allergies: AllergyListStatus.not_loaded)
      end

      def self.for_chart(patient, allergies)
        for_patient(patient, allergies: allergies, show_clear: false)
      end

      def self.for_patient(patient, allergies:, show_clear:)
        new(
          empty: false,
          show_clear: show_clear,
          demographics: patient && Demographics.from_patient(patient),
          allergies: allergies
        )
      end

      def initialize(empty:, show_clear:, demographics:, allergies:)
        @empty = empty
        @show_clear = show_clear
        @demographics = demographics
        @allergies = allergies
      end

      def empty?
        @empty
      end

      def show_clear?
        @show_clear
      end

      # Formatted demographics. Nil when the banner must not show identifiers.
      class Demographics
        attr_reader :name, :mrn, :dob_text, :age_text, :sex_text

        def self.from_patient(patient)
          new(
            name: patient.display_name.to_s,
            mrn: patient.dfn.to_s,
            dob_text: format_dob(patient.dob),
            age_text: format_age(patient),
            sex_text: format_sex(patient.sex)
          )
        end

        def self.format_dob(dob)
          return PatientBanner::MISSING if dob.blank?

          dob.strftime("%b %-d, %Y")
        end

        def self.format_age(patient)
          age = patient.age_on(Date.current)
          age.nil? ? PatientBanner::MISSING : age.to_s
        end

        def self.format_sex(sex)
          return PatientBanner::MISSING if sex.blank?

          PatientBanner::SEX_LABELS.fetch(sex, sex)
        end

        def initialize(name:, mrn:, dob_text:, age_text:, sex_text:)
          @name = name
          @mrn = mrn
          @dob_text = dob_text
          @age_text = age_text
          @sex_text = sex_text
        end
      end
    end
  end
end
