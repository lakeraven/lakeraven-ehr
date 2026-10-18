# frozen_string_literal: true

module Lakeraven
  module EHR
    # Display fields for the persistent banner. Values are already authorized
    # and already filtered; this object does not fetch.
    class PatientBanner
      SEX_LABELS = { "F" => "Female", "M" => "Male", "U" => "Unknown" }.freeze
      MISSING = "—"

      attr_reader :demographics, :allergies, :notice

      def self.empty
        new(empty: true, show_clear: false, demographics: nil, allergies: nil)
      end

      # Context is open, but nothing clinical may be shown.
      def self.closed
        new(empty: false, show_clear: true, demographics: nil,
            allergies: AllergyListStatus.not_loaded)
      end

      # The route names a patient the session has not opened. Demographics
      # would be the session patient's, on a page about someone else, so
      # they stay blank. Allergies are not fetched either. The field is
      # still present — not loaded, and nothing of the session patient's list.
      def self.unopened_route(route_dfn)
        new(
          empty: false, show_clear: true, demographics: nil,
          allergies: AllergyListStatus.not_loaded,
          notice: unopened_notice(route_dfn)
        )
      end

      # A name or a positive DFN is an identity. dfn 0 is what from_fhir
      # produces from a hash that had no id, and that is not a patient.
      def self.identifiable?(patient)
        return false unless patient.respond_to?(:display_name) && patient.respond_to?(:dfn)

        patient.display_name.to_s.strip.present? || patient.dfn.to_i.positive?
      end

      def self.unopened_notice(route_dfn)
        label = route_dfn.to_s
        return "This patient is not open" unless label.match?(/\A\d+\z/)

        "Patient ##{label} is not open"
      end
      private_class_method :unopened_notice

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

      def initialize(empty:, show_clear:, demographics:, allergies:, notice: nil)
        @empty = empty
        @show_clear = show_clear
        @demographics = demographics
        @allergies = allergies
        @notice = notice
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
