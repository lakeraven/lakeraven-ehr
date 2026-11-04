# frozen_string_literal: true

module Lakeraven
  module EHR
    # One of a patient's two contacts, the emergency contact or the next of kin,
    # as the front desk enters it (rpms-ux S-REG-08). PATIENT (#2) holds the name,
    # address and phones; IHS PATIENT (#9000001) holds the relationship.
    #
    # These checks are BPRM's (PatientProfile) and PATIENT's own rule that a
    # contact's other fields need its name (E1/K1^DGLOCK2). RPMS then runs AG's
    # own check of the name and zip (RpmsRpc::PatientProfile.update_contact).
    class ContactEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      KINDS = {
        "emergency" => "Emergency contact",
        "next_of_kin" => "Next of kin"
      }.freeze

      # LAST,FIRST MIDDLE with an optional ,SUFFIX, upper case as RPMS files it.
      NAME_FORMAT = /\A[A-Z][A-Z' -]*,[A-Z][A-Z' -]*(,[A-Z][A-Z' .-]*)?\z/
      ZIP_FORMAT = /\A\d{5}(-?\d{4})?\z/

      # Form attribute => RpmsRpc::PatientProfile field.
      FIELDS = {
        name: :name, relationship_ien: :relationship, address_line1: :address_line1, address_line2: :address_line2,
        city: :city, state_ien: :state, zip: :zip, phone: :phone, phone_work: :phone_work
      }.freeze

      attribute :name, :string
      attribute :relationship_ien, :string
      attribute :relationship_name, :string
      attribute :address_line1, :string
      attribute :address_line2, :string
      attribute :city, :string
      attribute :state_ien, :string
      attribute :state_name, :string
      attribute :zip, :string
      attribute :phone, :string
      attribute :phone_work, :string

      validates :name, format: { with: NAME_FORMAT, message: "must be LAST,FIRST MIDDLE,SUFFIX" },
                       length: { in: 3..35 }, allow_blank: true
      validates :zip, format: { with: ZIP_FORMAT, message: "must be 5 or 9 digits" }, allow_blank: true
      validate :name_with_other_fields

      # The entry as RPMS has it now (a RpmsRpc::PatientProfile contact hash).
      def self.from_rpms(contact)
        contact = contact.to_h
        new(name: contact[:name], relationship_ien: contact.dig(:relationship, :ien), relationship_name: contact.dig(:relationship, :name),
            address_line1: contact[:address_line1], address_line2: contact[:address_line2], city: contact[:city],
            state_ien: contact.dig(:state, :ien), state_name: contact.dig(:state, :name), zip: contact[:zip],
            phone: contact[:phone], phone_work: contact[:phone_work])
      end

      def initialize(attrs = {})
        super
        FIELDS.each_key { |key| public_send(:"#{key}=", public_send(key).to_s.strip.squeeze(" ").presence) }
        self.name = name&.upcase
      end

      def empty? = FIELDS.keys.all? { |key| public_send(key).blank? }

      # The fields the clerk changed from what RPMS has, as update_contact takes
      # them ("" clears). Only these are sent: a new name clears the old
      # contact's address and phones in RPMS, so an address left as it was is
      # not filed again for the new person (S-REG-08.2).
      def changes_from(current)
        FIELDS.each_with_object({}) do |(key, field), changes|
          mine = public_send(key).to_s
          next if mine == current.public_send(key).to_s

          changes[field] = mine
        end
      end

      private

      def name_with_other_fields
        return if name.present?
        return if FIELDS.except(:name).keys.all? { |key| public_send(key).blank? }

        errors.add(:name, "is needed for a relationship, address or phone")
      end
    end
  end
end
