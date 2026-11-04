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

      FIELDS = %i[address_line1 address_line2 address_line3 city state zip phone_home phone_work phone_other email].freeze
      EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

      FIELDS.each { |field| attribute field, :string }

      validates :address_line1, length: { in: 3..35 }, allow_blank: true
      validates :address_line2, :address_line3, length: { in: 3..30 }, allow_blank: true
      validates :city, length: { in: 2..28 }, allow_blank: true
      validates :zip, format: { with: /\A[A-Z0-9-]{1,10}\z/, message: "must be 1 to 10 letters and digits" }, allow_blank: true
      validates :phone_home, :phone_work, length: { in: 4..20, message: "must be 4 to 20 characters" }, allow_blank: true
      validates :phone_other, length: { in: 4..60, message: "must be 4 to 60 characters" }, allow_blank: true
      validates :email, length: { in: 3..50 }, allow_blank: true
      validates :email, format: { with: EMAIL, message: "must look like name@example.com" }, allow_blank: true

      # The form, filled from the record PatientRecordGateway.find returns.
      def self.from_record(record)
        new(FIELDS.to_h { |field| [ field, record[field].is_a?(Hash) ? record[field][:internal] : record[field] ] })
      end

      def initialize(attrs = {})
        super
        FIELDS.each { |field| public_send("#{field}=", public_send(field).to_s.strip.squeeze(" ").presence) }
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
    end
  end
end
