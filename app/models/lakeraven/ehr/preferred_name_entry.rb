# frozen_string_literal: true

module Lakeraven
  module EHR
    # The name the patient goes by (rpms-ux S-REG-12.1): PREFERRED NAME, IHS
    # PATIENT (9000001) field 9001, free text of 1 to 30 characters. Blank
    # clears it. It is saved in capitals, as RPMS keeps names: RPMS indexes it
    # with the family name for the patient search, and the search looks in
    # capitals, so only a name in capitals is found by it.
    class PreferredNameEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      MAX_LENGTH = 30

      attribute :name, :string

      validates :name, length: { maximum: MAX_LENGTH }, allow_blank: true
      validates :name, format: { without: /[\^[:cntrl:]]|\A@\z/, message: "cannot use ^ or @" }, allow_blank: true

      def initialize(attrs = {})
        super
        self.name = name.to_s.strip.upcase.squeeze(" ")
      end
    end
  end
end
