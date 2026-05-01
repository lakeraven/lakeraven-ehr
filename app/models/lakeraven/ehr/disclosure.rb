# frozen_string_literal: true

module Lakeraven
  module EHR
    # Disclosure -- PHI disclosure record
    #
    # ONC 170.315(d)(11) -- Accounting of Disclosures
    # HIPAA 164.528 -- Right to an Accounting of Disclosures
    class Disclosure < ApplicationRecord
      self.table_name = "lakeraven_ehr_disclosures"

      RETENTION_PERIOD = 6.years

      validates :patient_dfn, presence: true
      validates :recipient_name, presence: true
      validates :purpose, presence: true
      validates :data_disclosed, presence: true
      validates :disclosed_by, presence: true

      def readonly?
        persisted?
      end

      scope :for_patient, ->(dfn) { where(patient_dfn: dfn) }
      scope :within_retention, -> { where(disclosed_at: RETENTION_PERIOD.ago..) }

      def self.accounting_for_patient(patient_dfn)
        for_patient(patient_dfn).within_retention.order(disclosed_at: :desc)
      end
    end
  end
end
