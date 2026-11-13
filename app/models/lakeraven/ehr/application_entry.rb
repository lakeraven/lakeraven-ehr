# frozen_string_literal: true

module Lakeraven
  module EHR
    # A patient's application for coverage, as the front desk records it
    # (rpms-ux S-REG-03.3): the type (PATIENT APPLICATION TYPES, 9000048), the
    # day the patient applied (DATE APPLICATION OBTAINED, 9000045.11 .01, not in
    # the future), and when and how it was sent (DATE APPLICATION SUBMITTED and
    # SUBMITTED VIA, 9000045.1101 .01 and .02). RPMS files it as pending.
    class ApplicationEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      # SUBMITTED VIA (9000045.1101 .02), in the clerk's words.
      SUBMITTED_VIA = { "O" => "Online", "M" => "Mail", "F" => "Fax", "H" => "Hand delivered", "T" => "Telephone" }.freeze

      attribute :type_ien, :integer
      attribute :applied_on, :date
      attribute :submitted_on, :date
      attribute :submitted_via, :string

      validates :type_ien, presence: { message: "is needed: choose the kind of application" }
      validates :applied_on, presence: { message: "is needed" }
      validates :submitted_via, inclusion: { in: SUBMITTED_VIA.keys }, allow_blank: true
      validate :not_in_the_future
      validate :submitted_after_applied

      private

      def not_in_the_future
        errors.add(:applied_on, "cannot be in the future") if applied_on && applied_on > SiteDate.today
      end

      def submitted_after_applied
        return unless applied_on && submitted_on

        errors.add(:submitted_on, "cannot be before the day the patient applied") if submitted_on < applied_on
      end
    end
  end
end
