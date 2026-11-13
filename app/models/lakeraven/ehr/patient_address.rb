# frozen_string_literal: true

module Lakeraven
  module EHR
    # Where a registered patient lives and how to reach them (rpms-ux S-REG-21):
    # the mailing address, the home, work and other phones, and the email.
    #
    # The lengths and forms here are BPRM's ChangeAddressCommandValidator: street
    # lines 3 to 35 (line 1) or 30 characters, city 2 to 28, zip 1 to 10 letters
    # and digits, phones 4 to 20 (other phone 60), email 3 to 50 in email form.
    # AG checks the zip again (5 or 9 digits, ZIP^AGGWVAL) before it files, and
    # its refusal is shown as it is.
    class PatientAddress
      include ActiveModel::Model
      include ActiveModel::Attributes
      include SiteRequiredFields

      FIELDS = %i[address_line1 address_line2 address_line3 city state zip phone_home phone_work phone_other email].freeze
      EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

FIELDS.each { |field| attribute field, :string }
# The date the patient moved (S-REG-21.1): RPMS ends the old address on
# it in PREVIOUS MAIL ADDRESSES and starts the new one from it. Today
# unless the clerk says otherwise.
attribute :moved_on, :date
# The fields whose change keeps the old address (ADR^AGGUL1 copies these).
HISTORY_FIELDS = %i[address_line1 address_line2 address_line3 city state zip phone_home].freeze
EARLIEST_MOVE = Date.new(1871, 1, 1)

      # The fields a site may make mandatory in RPMS (#980): PATIENT (2) and
      # IHS PATIENT (9000001) fields, by the label REGISTRATION PARAMETERS lists
      # them under. AG asks them required when the site says so (AG3A, AGAPIPAT).
      site_required address_line1: [ "2", "STREET ADDRESS [LINE 1]" ], city: [ "2", "CITY" ], state: [ "2", "STATE" ],
                    zip: [ "2", "ZIP CODE" ], phone_home: [ "2", "PHONE NUMBER [RESIDENCE]" ],
                    phone_work: [ "2", "PHONE NUMBER [WORK]" ], email: [ "9000001", "CURRENT EMAIL ADDRESS" ]

      validates :address_line1, length: { in: 3..35 }, allow_blank: true
      validates :address_line2, :address_line3, length: { in: 3..30 }, allow_blank: true
      validates :city, length: { in: 2..28 }, allow_blank: true
      validates :zip, format: { with: /\A[A-Z0-9-]{1,10}\z/, message: "must be 1 to 10 letters and digits" }, allow_blank: true
      validates :phone_home, :phone_work, length: { in: 4..20, message: "must be 4 to 20 characters" }, allow_blank: true
      validates :phone_other, length: { in: 4..60, message: "must be 4 to 60 characters" }, allow_blank: true
      validates :email, length: { in: 3..50 }, allow_blank: true
      validate :moved_on_in_range
      validates :email, format: { with: EMAIL, message: "must look like name@example.com" }, allow_blank: true

      # The fields in the clerk's words, as the form labels them.
      NAMES = { moved_on: "Date they moved", address_line1: "Street address", zip: "Zip code", phone_home: "Home phone",
                phone_work: "Work phone", phone_other: "Other phone", email: "Email" }.freeze

      def self.human_attribute_name(attribute, options = {})
        NAMES.fetch(attribute.to_sym) { super }
      end

      # The form, filled from the record PatientRecordGateway.find returns.
      def self.from_record(record)
        new(FIELDS.to_h { |field| [ field, record[field].is_a?(Hash) ? record[field][:internal] : record[field] ] })
      end

      def initialize(attrs = {})
        super
        FIELDS.each { |field| public_send("#{field}=", public_send(field).to_s.strip.squeeze(" ").presence) }
        self.moved_on ||= Date.current
        %i[address_line1 address_line2 address_line3 city zip].each do |field|
          public_send("#{field}=", public_send(field)&.upcase)
        end
      end

      # The attributes that differ from what RPMS holds, as RpmsRpc::Patient.update
      # takes them. An emptied field is sent as "", which clears it.
      def changes_from(current)
        FIELDS.each_with_object({}) do |field, out|
          value = public_send(field).to_s
          out[field] = value unless value == current.public_send(field).to_s
        end
      end

      # True when the change moves the patient, so RPMS keeps the old address.
      def moves?(changes) = changes.keys.intersect?(HISTORY_FIELDS)

      private

      def moved_on_in_range
        if moved_on > Date.current
          errors.add(:moved_on, "cannot be in the future")
        elsif moved_on < EARLIEST_MOVE
          errors.add(:moved_on, "cannot be before 1871")
        end
      end
    end
  end
end
