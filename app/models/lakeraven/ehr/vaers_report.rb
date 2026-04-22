# frozen_string_literal: true

require "csv"

module Lakeraven
  module EHR
    class VaersReport
      include ActiveModel::Model
      include ActiveModel::Validations

      attr_accessor :patient_dfn, :immunization_id, :patient_name, :patient_dob,
                    :patient_sex, :vaccine_name, :vaccine_date, :adverse_event,
                    :onset_date

      validates :patient_dfn, presence: true
      validates :immunization_id, presence: true

      HEADERS = %w[
        VAERS_ID RECVDATE STATE AGE_YRS SEX SYMPTOM_TEXT
        VACCINE_TYPE VACCINE_DATE ONSET_DATE
      ].freeze

      def to_vaers
        {
          patient_name: patient_name,
          patient_dob: patient_dob,
          patient_sex: patient_sex,
          vaccine_name: vaccine_name,
          vaccine_date: vaccine_date,
          adverse_event: adverse_event,
          onset_date: onset_date
        }
      end

      def to_csv
        CSV.generate do |csv|
          csv << HEADERS
          csv << [
            nil, Date.current.iso8601, nil, nil, patient_sex,
            adverse_event, vaccine_name, vaccine_date, onset_date
          ]
        end
      end
    end
  end
end
