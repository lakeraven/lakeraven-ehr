# frozen_string_literal: true

module Lakeraven
  module EHR
    # An other name the patient has used (rpms-ux S-REG-12.2): an entry of the
    # ALIAS multiple of PATIENT (#2.01). The format and length are the
    # multiple's own (its .01 input transform); RPMS then runs AG's name check.
    class OtherNameEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :name, :string

      validates :name, presence: true
      validates :name, format: { with: PatientRegistration::NAME_FORMAT, message: "must be LAST,FIRST MIDDLE" },
                       length: { in: 3..30 }, allow_blank: true

      def initialize(attrs = {})
        super
        self.name = name.to_s.strip.upcase.squeeze(" ").presence
      end
    end
  end
end
