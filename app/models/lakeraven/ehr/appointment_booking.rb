# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the scheduler enters to book an appointment (rpms-ux S-SCH-01), and
    # the rules that refuse it before anything reaches the broker: a missing
    # patient, date, time or length (S-SCH-01.3) and a note outside 2 to 150
    # characters or carrying a semicolon or colon (S-SCH-01.4).
    class AppointmentBooking
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :resource, :string
      attribute :dfn, :integer
      attribute :date, :date
      attribute :time, :string
      attribute :minutes, :integer
      attribute :note, :string

      validates :resource, :dfn, :date, :time, :minutes, presence: true
      validates :time, format: { with: /\A\d{1,2}:\d{2}\z/, message: "must be HH:MM" }, allow_blank: true
      validates :minutes, numericality: { greater_than: 0 }, allow_blank: true
      validates :note, length: { in: 2..150 }, allow_blank: true
      validates :note, format: { without: /[;:]/, message: "must not contain a semicolon or a colon" }, allow_blank: true

      attr_reader :result

      # A refusal names the value as the scheduler sees it on the form.
      HUMAN_NAMES = {
        "resource" => "Clinic", "dfn" => "Patient record number", "date" => "Date",
        "time" => "Time", "minutes" => "Length in minutes", "note" => "Note"
      }.freeze

      def self.human_attribute_name(attribute, options = {})
        HUMAN_NAMES.fetch(attribute.to_s) { super }
      end

      def start_time
        return nil if date.blank? || time.blank?

        Time.zone.parse("#{date} #{time}")
      end

      def book(gateway: AppointmentBookingGateway)
        return false unless valid?

        @result = gateway.book(resource: resource.strip, dfn: dfn, start_time: start_time,
                               minutes: minutes, note: note.presence)
        return true if @result[:success]

        errors.add(:base, @result[:error])
        false
      end

      def appointment_id = result&.dig(:appointment_id)
    end
  end
end
