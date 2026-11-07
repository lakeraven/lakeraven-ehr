# frozen_string_literal: true

module Lakeraven
  module EHR
    # Forwarding a notification to a colleague (rpms-ux S-SGN-02.4): whom to,
    # a user chosen from a search of RPMS's users, by DUZ, and an optional
    # comment. Kernel takes a comment of at most 245 characters (XQALFWD) and
    # keeps it as a caret piece of the recipient's alert, so it holds no caret.
    class NotificationForward
      include ActiveModel::Model
      include ActiveModel::Attributes

      COMMENT_MAX = ::RpmsRpc::Notifications::COMMENT_MAX

      attribute :recipient_duz, :string
      attribute :comment, :string

      validates :recipient_duz, presence: { message: "is needed: find your colleague by name and choose them" }
      validates :comment, length: { maximum: COMMENT_MAX, message: "is at most %{count} characters" }
      validate :no_caret

      NAMES = { "recipient_duz" => "Colleague", "comment" => "Comment" }.freeze

      def self.human_attribute_name(attribute, options = {}) = NAMES.fetch(attribute.to_s) { super }

      private

      def no_caret
        errors.add(:comment, "cannot contain the ^ character") if comment.to_s.include?("^")
      end
    end
  end
end
