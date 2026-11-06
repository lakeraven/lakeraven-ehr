# frozen_string_literal: true

module Lakeraven
  module EHR
    # The migrant, homeless and internet questions as the front desk asks them
    # (rpms-ux S-REG-11, S-REG-22.5, S-REG-31.3). Each answer is a new entry
    # dated today, kept beside the earlier ones, so a question left unanswered
    # is not sent and nothing is filed for it.
    #
    # The rules are AG's (its window's triggers, AGGPTRGO): yes needs its type,
    # and a no takes none, so a type left on a no is dropped.
    class SocialStatusEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      ANSWERS = { "Y" => "Yes", "N" => "No" }.freeze
      # #9000001.84 .03 and #9000001.85 .03.
      MIGRANT_TYPES = { "M" => "Migrant agricultural worker", "S" => "Seasonal agricultural worker" }.freeze
      HOMELESS_TYPES = { "H" => "Homeless shelter", "T" => "Transitional", "D" => "Doubling up",
                         "S" => "Street", "O" => "Other", "U" => "Unknown" }.freeze

      attribute :migrant, :string
      attribute :migrant_type, :string
      attribute :homeless, :string
      attribute :homeless_type, :string
      attribute :internet, :string

      validates :migrant, :homeless, :internet, inclusion: { in: ANSWERS.keys }, allow_blank: true
      validates :migrant_type, inclusion: { in: MIGRANT_TYPES.keys, message: "is needed for a migrant worker" }, if: -> { migrant == "Y" }
      validates :homeless_type, inclusion: { in: HOMELESS_TYPES.keys, message: "is needed for a homeless patient" }, if: -> { homeless == "Y" }
      validate :something_answered

      # What RpmsRpc::PatientProfile.record_social_status takes.
      def record_attrs
        { migrant: migrant.presence, migrant_type: (migrant_type if migrant == "Y"),
          homeless: homeless.presence, homeless_type: (homeless_type if homeless == "Y"),
          internet: (internet == "Y" if internet.present?) }.compact
      end

      private

      def something_answered
        errors.add(:base, "Answer at least one question") if [ migrant, homeless, internet ].all?(&:blank?)
      end
    end
  end
end
