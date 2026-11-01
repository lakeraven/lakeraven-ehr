# frozen_string_literal: true

module Lakeraven
  module EHR
    # One inbound ServiceRequest waiting for staff triage. The row is not an
    # RPMS referral: a system token has no broker session (ADR 0011), so this
    # slice only stores the intake record.
    class InboundReferral < ApplicationRecord
      self.table_name = "lakeraven_ehr_inbound_referrals"

      # Queue state. The FHIR status stays inside `resource`.
      RECEIVED = "received"

      has_many :identifiers,
               class_name: "Lakeraven::EHR::InboundReferralIdentifier",
               inverse_of: :inbound_referral,
               dependent: :destroy

      before_validation :assign_public_id, on: :create

      # The stored body, with the server id. The client's id and meta are
      # not kept on `resource`.
      def to_fhir
        resource.merge("id" => public_id)
      end

      private

      def assign_public_id
        self.public_id = SecureRandom.uuid if public_id.blank?
      end
    end
  end
end
