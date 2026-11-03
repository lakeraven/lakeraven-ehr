# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler corrects on an appointment without rebooking it (rpms-ux
    # S-SCH-09): a booked appointment's note and, at a clinic that allows
    # variable lengths, its length; a cancelled or no-show appointment's
    # remarks. The rules are the ones booking and cancelling keep.
    class AppointmentDetails
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :note, :string
      attribute :length, :integer
      attribute :remarks, :string

      # :booked or :closed (cancelled or no-show), set by the controller.
      attr_accessor :kind

      validates :note, length: { in: 2..150 }, allow_blank: true, if: -> { kind == :booked }
      validates :note, format: { without: /[;:]/, message: "cannot contain a semicolon or a colon" }, allow_blank: true, if: -> { kind == :booked }
      validates :length, numericality: { greater_than: 0, allow_nil: true }, if: -> { kind == :booked }
      validates :remarks, length: { in: 3..160 }, if: -> { kind == :closed }
      validates :remarks, format: { without: /[\^]/, message: "cannot contain a caret" }, if: -> { kind == :closed }

      def initialize(attrs = {})
        super
        self.note = note.to_s.strip
        self.remarks = remarks.to_s.strip
      end
    end
  end
end
