# frozen_string_literal: true

module Lakeraven
  module EHR
    # Banner data for layout pages. Patient demographics and allergies are
    # authorized separately. Allergies are displayed only from what the
    # egress filter returned. If the patient record itself cannot be loaded,
    # nothing clinical is shown — there is no one to attach a list to.
    class PatientBannerLoader
      def initialize(dfn:, can_read:, filter:)
        @dfn = dfn
        @can_read = can_read
        @filter = filter
      end

      def load
        patient = resolve_patient
        return PatientBanner.closed if patient == :unavailable

        PatientBanner.for_patient(patient, allergies: allergy_status, show_clear: true)
      end

      private

      # nil: demographics are not authorized (allergies may still be).
      # :unavailable: a Patient read was allowed and the record did not load.
      def resolve_patient
        return nil unless @can_read.call("Patient")

        found = find_patient
        return :unavailable if found.nil?

        filtered_patient(found)
      end

      def find_patient
        Patient.find_by_dfn(@dfn)
      rescue StandardError => e
        Rails.logger.warn("[patient-banner] patient load failed: #{e.class}")
        nil
      end

      def filtered_patient(patient)
        filtered = @filter.call(patient.to_fhir)
        return nil unless filtered.is_a?(Hash)

        Patient.from_fhir(deep_stringify(filtered))
      rescue StandardError => e
        Rails.logger.warn("[patient-banner] patient egress failed: #{e.class}")
        nil
      end

      def allergy_status
        return AllergyListStatus.not_loaded unless @can_read.call("AllergyIntolerance")

        source = fetch_allergies
        AllergyListStatus.from_counts(
          source_status: source.status,
          source_count: source.records.length,
          filtered_names: filtered_allergy_names(source)
        )
      end

      def fetch_allergies
        AllergySource.fetch(log_label: "[patient-banner]") do
          SupplementalClinicalResources.merged_allergy_intolerances_for_patient(@dfn)
        end
      end

      def filtered_allergy_names(source)
        return nil unless source.ok?

        AllergyListStatus.names_in(@filter.call(AllergySource.bundle(source.records)))
      rescue StandardError => e
        Rails.logger.warn("[patient-banner] allergy egress failed: #{e.class}")
        nil
      end

      # Patient.from_fhir only stringifies the top-level hash. Nested name
      # and identifier keys stay symbols unless this walks them, and a symbol
      # key reads back as a blank name.
      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, inner), copy| copy[key.to_s] = deep_stringify(inner) }
        when Array
          value.map { |inner| deep_stringify(inner) }
        else
          value
        end
      end
    end
  end
end
