# frozen_string_literal: true

module Lakeraven
  module EHR
    # A clinic's scheduling settings as a scheduling supervisor edits them
    # (rpms-ux S-SCH-15): fields of the clinic's HOSPITAL LOCATION (#44) entry
    # and of its CLINIC SETUP PARAMETERS (#9009017.2) entry, read and filed
    # through RpmsRpc::SchedulingSetup. These checks are BPRM's clinic
    # validator's, so a bad value is named before RPMS is asked (S-SCH-15.2);
    # FileMan's own input transforms still decide on the write.
    class ClinicSettings
      include ActiveModel::Model
      include ActiveModel::Attributes

      # DISPLAY INCREMENTS PER HOUR (#44 field 1917): the code is how many
      # increments make an hour.
      INCREMENTS = { 1 => "60 minutes", 2 => "30 minutes", 3 => "20 minutes", 4 => "15 minutes", 6 => "10 minutes" }.freeze
      # The four letter types, each a #44 field pointing at LETTER (#407.5).
      LETTERS = { no_show_letter: :no_show, pre_appointment_letter: :pre_appointment,
                  clinic_cancellation_letter: :clinic_cancellation, appointment_cancellation_letter: :appointment_cancellation }.freeze
      LETTER_LABELS = { no_show: "No-show letter", pre_appointment: "Pre-appointment letter",
                        clinic_cancellation: "Clinic cancellation letter", appointment_cancellation: "Appointment cancellation letter" }.freeze
      LABELS = {
        abbreviation: "Abbreviation", stop_code: "Clinic code", meets_at_facility: "Meets at this facility",
        non_count: "Non-count clinic", include_on_file_room_lists: "Include on file room lists",
        prohibit_access: "Prohibit access to clinic", length_minutes: "Length of appointment (minutes)",
        variable_length: "Variable length appointments", display_begins: "Hour the schedule begins",
        increments_per_hour: "Display increments", overbooks_per_day: "Overbooks per day (maximum)",
        allowable_no_shows: "Allowable consecutive no-shows", max_future_days: "Maximum days for future booking",
        schedule_on_holidays: "Schedule on holidays", no_show_waiting_days: "No-show waiting period (days)",
        create_visit_at_checkin: "Create visit at check-in", visit_provider_required: "Provider required for visit"
      }.merge(LETTERS.transform_values { |type| LETTER_LABELS[type] }).freeze
      FLAGS = %i[variable_length schedule_on_holidays prohibit_access non_count include_on_file_room_lists meets_at_facility
                 create_visit_at_checkin visit_provider_required].freeze
      NUMBERS = %i[length_minutes display_begins increments_per_hour overbooks_per_day allowable_no_shows max_future_days
                   no_show_waiting_days].freeze
      POINTERS = (%i[stop_code] + LETTERS.keys).freeze

      attribute :abbreviation, :string
      NUMBERS.each { |name| attribute name, :integer }
      FLAGS.each { |name| attribute name, :boolean, default: false }
      POINTERS.each { |name| attribute name, :integer }

      validates :abbreviation, presence: true, length: { maximum: 7 }
      validates :length_minutes, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 10, less_than_or_equal_to: 240, allow_nil: true }
      validates :increments_per_hour, inclusion: { in: INCREMENTS.keys, message: "must be one of 60, 30, 20, 15 or 10 minutes" }
      validates :overbooks_per_day, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 9999, allow_nil: true }
      validates :allowable_no_shows, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 999, allow_nil: true }
      validates :max_future_days, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 999, allow_nil: true }
      validates :display_begins, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 16, allow_nil: true }
      validates :no_show_waiting_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 999, allow_nil: true }
      validates :stop_code, presence: { message: "is required: choose a clinic code" }
      validate :length_fits_the_increments

      # Errors name a setting as the page labels it.
      def self.human_attribute_name(attribute, options = {})
        LABELS.fetch(attribute.to_sym) { super }
      end

      # The form for what SchedulingSetup.clinic_settings read.
      def self.from_rpms(settings)
        values = settings.slice(:abbreviation, *NUMBERS, *FLAGS)
        POINTERS.each { |name| values[name] = settings.dig(name, :id) }
        FLAGS.each { |name| values[name] = values[name] ? true : false }
        new(values)
      end

      # The settings that differ from what RPMS holds, as
      # SchedulingSetup.update_clinic_settings takes them. A clinic with no
      # CLINIC SETUP PARAMETERS entry reads its flags as off, so the entry is
      # added only when one of them is turned on.
      def changes_from(settings)
        current = self.class.from_rpms(settings)
        changed = attribute_names.map(&:to_sym).reject { |name| public_send(name) == current.public_send(name) }
        changed.to_h { |name| [ name, public_send(name) ] }
      end

      def increment_minutes = INCREMENTS.key?(increments_per_hour) ? 60 / increments_per_hour : nil

      private

      # LENGTH OF APP'T must be a multiple of 10 or 15 and of the minutes in one
      # display increment: FileMan's transforms on #44 fields 1912 and 1917.
      def length_fits_the_increments
        return unless length_minutes

        errors.add(:length_minutes, "must be a multiple of 10 or 15 minutes") unless (length_minutes % 10).zero? || (length_minutes % 15).zero?
        minutes = increment_minutes
        return if minutes.nil? || (length_minutes % minutes).zero?

        errors.add(:length_minutes, "must be a multiple of the display increment (#{minutes} minutes)")
      end
    end
  end
end
