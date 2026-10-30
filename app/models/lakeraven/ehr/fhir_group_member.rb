# frozen_string_literal: true

module Lakeraven
  module EHR
    # One patient in a bulk-export cohort. RPMS has no FHIR Group, so the
    # membership list lives in this table and Group#show reads it.
    # group_id uses that action's FHIR id grammar; patient_dfn is a
    # positive integer string with no leading zero.
    class FhirGroupMember < ApplicationRecord
      self.table_name = "lakeraven_ehr_fhir_group_members"

      validates :group_id, presence: true, format: { with: GroupsController::FHIR_ID_PATTERN }
      validates :patient_dfn, presence: true, uniqueness: { scope: :group_id },
                format: { with: /\A[1-9]\d*\z/ }

      def self.members_of(group_id)
        where(group_id: group_id).order(:patient_dfn)
      end
    end
  end
end
