# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART EHR launch context — DB-backed token that binds a patient
    # (and optionally an encounter) to an OAuth authorization flow.
    #
    # The host app calls LaunchContext.mint when the EHR user initiates
    # a SMART app launch. The token endpoint calls LaunchContext.resolve
    # to look up the patient context and include it in the token response.
    #
    # Same pattern as Doorkeeper: engine owns the table + model,
    # host app wires it to their auth/session.
    class LaunchContext < ApplicationRecord
      self.table_name = "lakeraven_ehr_launch_contexts"

      DEFAULT_TTL = 5.minutes

      validates :launch_token, presence: true, uniqueness: true
      validates :oauth_application_uid, presence: true
      validates :expires_at, presence: true

      # Mint a new launch context with a unique token.
      def self.mint(oauth_application_uid:, patient_dfn: nil, encounter_id: nil, facility_identifier: nil, ttl: DEFAULT_TTL)
        create!(
          launch_token: generate_token,
          oauth_application_uid: oauth_application_uid,
          patient_dfn: patient_dfn,
          encounter_id: encounter_id,
          facility_identifier: facility_identifier,
          expires_at: Time.current + ttl
        )
      end

      # Resolve a launch token to its context. Returns nil if expired or not found.
      def self.resolve(token)
        find_by("launch_token = ? AND expires_at > ?", token, Time.current)
      end

      # SMART context fields for the token response.
      def to_smart_context
        context = {}
        context[:patient] = patient_dfn if patient_dfn.present?
        context[:encounter] = encounter_id if encounter_id.present?
        context
      end

      def self.generate_token
        "lc_#{SecureRandom.urlsafe_base64(24)}"
      end
      private_class_method :generate_token
    end
  end
end
