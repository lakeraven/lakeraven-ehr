# frozen_string_literal: true

module Lakeraven
  module EHR
    # One answer about a patient's advance directive, as the front desk records
    # it (rpms-ux S-REG-17): the date of entry, whether the patient has one, its
    # type when they do, and the reason when they do not. RPMS keeps it in the
    # DATE OF ENTRY multiple (9000040.11) of ADVANCE DIRECTIVE (9000040).
    #
    # The rules are BPRM's and AG's (rpms-ux S-REG-17.4): a date is needed; yes
    # needs a type and keeps no reason; no needs a reason of 3 to 30 characters
    # and keeps no type, so the one the answer does not keep is dropped.
    class AdvanceDirectiveEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      ANSWERS = { "Y" => "Yes", "N" => "No" }.freeze
      REASON_LENGTH = (3..30)
      NAMES = { "entered_on" => "Date of entry", "directive" => "Advance directive", "type_ien" => "Type", "reason" => "Reason" }.freeze

      attribute :entered_on, :date
      attribute :directive, :string
      attribute :type_ien, :integer
      attribute :reason, :string

      validates :entered_on, presence: { message: "is needed" }
      validates :directive, inclusion: { in: ANSWERS.keys, message: "is needed: say whether the patient has one" }
      validates :type_ien, presence: { message: "is needed for an advance directive" }, if: -> { directive == "Y" }
      validates :reason, presence: { message: "is needed when there is no advance directive" }, if: -> { directive == "N" }
      validates :reason, length: { in: REASON_LENGTH, message: "must be 3 to 30 characters" },
                         if: -> { directive == "N" && reason.present? }

      def self.human_attribute_name(attribute, options = {}) = NAMES.fetch(attribute.to_s) { super }

      # An entry on file (RpmsRpc::Registration.advance_directives), to edit.
      def self.from_row(row)
        new(entered_on: row[:entered_on], directive: row[:directive] ? "Y" : "N", type_ien: row[:type_ien], reason: row[:reason])
      end

      # What RpmsRpc::Registration.record_advance_directive and
      # change_advance_directive take.
      def record_attrs
        has = directive == "Y"
        { directive: has, type: (type_ien if has), reason: (reason.to_s.strip unless has), entered_on: entered_on }
      end
    end
  end
end
