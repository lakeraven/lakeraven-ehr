# frozen_string_literal: true

module Lakeraven
  module EHR
    # Another tribe of a patient's, as the front desk records it (rpms-ux
    # S-REG-07.2). That it is not the tribe of membership, not listed twice, and
    # that the quantums add up are checked by RpmsRpc::PatientProfile.
    class OtherTribeEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :tribe_ien, :integer
      attribute :quantum, :string

      validates :tribe_ien, presence: { message: "is required: find the tribe" }
      validates :quantum, format: { with: PatientEligibility::QUANTUM, message: "must be a fraction like 1/4, or FULL, UNKNOWN or NONE" },
                          allow_blank: true

      def initialize(attrs = {})
        super
        self.quantum = quantum.to_s.strip.upcase.presence
      end
    end
  end
end
