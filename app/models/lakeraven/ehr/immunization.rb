# frozen_string_literal: true

module Lakeraven
  module EHR
    class Immunization
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :vaccine_code, :string
      attribute :vaccine_display, :string
      attribute :status, :string
      attribute :lot_number, :string
      attribute :expiration_date, :date
      attribute :site, :string
      attribute :route, :string
      attribute :performer_duz, :string
      attribute :performer_name, :string
      attribute :occurrence_datetime, :datetime
      attribute :dose_quantity, :float
      attribute :dose_unit, :string
      attribute :manufacturer, :string

      # VIS (Vaccine Information Statement) metadata
      attribute :vis_edition_date, :date
      attribute :vis_presentation_date, :date
      attribute :vis_document_uri, :string

      # VFC eligibility and funding
      attribute :vfc_eligibility_code, :string
      attribute :funding_source, :string

      validates :patient_dfn, presence: true
      validates :vaccine_display, presence: true
      validates :status, inclusion: {
        in: %w[completed entered-in-error not-done],
        allow_blank: true
      }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || ImmunizationGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      def self.find_by_ien(ien)
        gateway.find(ien)
      end

      def self.resource_class
        "Immunization"
      end

      def persisted?
        ien.present?
      end

      def completed? = status == "completed"
      def not_done? = status == "not-done"
      def entered_in_error? = status == "entered-in-error"

      def to_fhir
        {
          resourceType: "Immunization",
          id: ien&.to_s,
          meta: { profile: [ "http://hl7.org/fhir/us/core/StructureDefinition/us-core-immunization" ] },
          status: status,
          patient: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          vaccineCode: build_vaccine_code,
          occurrenceDateTime: occurrence_datetime&.iso8601,
          lotNumber: lot_number,
          site: site.present? ? { text: site } : nil,
          route: route.present? ? { text: route } : nil,
          performer: build_performers,
          education: build_education,
          programEligibility: build_program_eligibility,
          fundingSource: build_funding_source
        }.compact
      end

      private

      def build_vaccine_code
        return nil unless vaccine_code || vaccine_display

        result = {}
        if vaccine_code
          result[:coding] = [ { system: "http://hl7.org/fhir/sid/cvx", code: vaccine_code } ]
        end
        result[:text] = vaccine_display if vaccine_display
        result
      end

      def build_performers
        return nil if performer_duz.blank?

        [ {
          actor: {
            reference: "Practitioner/#{performer_duz}",
            display: performer_name
          }
        } ]
      end

      def build_education
        return nil if vis_edition_date.blank? && vis_presentation_date.blank?

        [ {
          reference: vis_document_uri,
          publicationDate: vis_edition_date&.iso8601,
          presentationDate: vis_presentation_date&.iso8601
        } ]
      end

      # VFC eligibility V-code -> HL7 standard eligible/ineligible mapping
      VFC_ELIGIBLE_CODES = %w[V02 V03 V04 V05 V06 V07].freeze

      def build_program_eligibility
        return nil if vfc_eligibility_code.blank?

        standard_code = VFC_ELIGIBLE_CODES.include?(vfc_eligibility_code) ? "eligible" : "ineligible"

        [ {
          coding: [
            {
              system: "https://www.ihs.gov/rpms/fhir/CodeSystem/vfc-eligibility",
              code: vfc_eligibility_code
            },
            {
              system: "http://terminology.hl7.org/CodeSystem/immunization-program-eligibility",
              code: standard_code
            }
          ]
        } ]
      end

      # Funding source -> HL7 standard public/private mapping
      FUNDING_SOURCE_PUBLIC = %w[VFC VFA].freeze

      def build_funding_source
        return nil if funding_source.blank?

        standard_code = FUNDING_SOURCE_PUBLIC.include?(funding_source) ? "public" : "private"

        {
          coding: [
            {
              system: "https://www.ihs.gov/rpms/fhir/CodeSystem/immunization-funding-source",
              code: funding_source
            },
            {
              system: "http://terminology.hl7.org/CodeSystem/immunization-funding-source",
              code: standard_code
            }
          ]
        }
      end
    end
  end
end
