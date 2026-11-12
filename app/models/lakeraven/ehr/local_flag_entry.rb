# frozen_string_literal: true

module Lakeraven
  module EHR
    # A local patient record flag as a site manager defines it (lakeraven-ehr#983):
    # the fields of PRF LOCAL FLAG (#26.11) BPRM edits, and on a change the
    # reason DGPF and BPRM require. The limits are the file's own (its input
    # transforms) and DGPF's: notification days are not more than review
    # frequency days. RPMS checks again when it files.
    class LocalFlagEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :name, :string
      attribute :type_ien, :integer
      attribute :active, :boolean, default: true
      attribute :review_days, :integer
      attribute :notification_days, :integer
      attribute :description, :string
      attribute :reason, :string
      attribute :editing, :boolean, default: false
      # The PRF TYPE IENs this page does not file (the Behavioral type, #291).
      attribute :withheld_types, default: -> { [] }

      validates :name, presence: true
      validates :name, format: { with: /\A[A-Z][A-Z0-9 ]{2,29}\z/,
                                 message: "must be 3 to 30 letters, digits and spaces, starting with a letter" }, allow_blank: true
      validates :type_ien, presence: true
      validates :review_days, numericality: { only_integer: true, in: 0..9999 }
      validates :notification_days, numericality: { only_integer: true, in: 0..9998 }
      validates :reason, presence: true, if: :editing
      validate :notice_within_review
      validate :type_not_withheld

      def self.from_flag(flag)
        new(name: flag[:name], type_ien: flag[:type_ien], active: flag[:active], review_days: flag[:review_days],
            notification_days: flag[:notification_days], description: Array(flag[:description]).join("\n"), editing: true)
      end

      def initialize(attrs = {})
        super
        self.name = name.to_s.strip.upcase.squeeze(" ").presence
      end

      def description_lines = lines(description)
      def reason_lines = lines(reason)

      private

      def lines(text) = text.to_s.split(/\r?\n/).map(&:rstrip).reject(&:empty?)

      def notice_within_review
        return unless review_days.is_a?(Integer) && notification_days.is_a?(Integer)
        return unless notification_days > review_days

        errors.add(:notification_days, "cannot be more than the review frequency days")
      end

      def type_not_withheld
        return unless type_ien && Array(withheld_types).include?(type_ien)

        errors.add(:type_ien, "Behavioral waits on the Part 2 decision; choose another type")
      end
    end
  end
end
