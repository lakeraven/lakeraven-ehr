# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to take a patient off a wait list (rpms-ux S-SCH-10.5, 10.6).
    class WaitListRemoval
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :removed_on, :date
      attribute :resolution_ien, :integer

      validates :removed_on, presence: { message: "is required" }
      validates :resolution_ien, presence: { message: "is required" }
    end
  end
end
