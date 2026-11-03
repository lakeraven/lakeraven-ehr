# frozen_string_literal: true

module Lakeraven
  module EHR
    # One Identifier from an inbound ServiceRequest. oauth_application_id is
    # denormalized so uniqueness is per client in the database, not a model
    # validation.
    class InboundReferralIdentifier < ApplicationRecord
      self.table_name = "lakeraven_ehr_inbound_referral_identifiers"

      belongs_to :inbound_referral,
                 class_name: "Lakeraven::EHR::InboundReferral",
                 inverse_of: :identifiers
    end
  end
end
