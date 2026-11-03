# frozen_string_literal: true

module Lakeraven
  module EHR
    # A patient's tribal standing as the front desk records it (rpms-ux
    # S-REG-07.1): eligibility status, classification, tribe of membership,
    # Indian blood quantum, tribe quantum and tribal enrollment number, all on
    # IHS PATIENT (#9000001) through AG's Eligibility window.
    #
    # Whether the values agree with each other (S-REG-07.4, 07.5) is AG's own
    # check, not this model's.
    class PatientEligibility
      include ActiveModel::Model
      include ActiveModel::Attributes

      # ELIGIBILITY STATUS, #9000001 1112 (the set of codes on the DD).
      STATUSES = { "C" => "CHS and direct care", "D" => "Direct care only", "P" => "Pending verification",
                   "I" => "Not eligible" }.freeze
      # The form's attribute => the RpmsRpc::Registration.update attribute.
      UPDATE_NAMES = { eligibility_status: :eligibility_status, classification_ien: :classification, tribe_ien: :tribe,
                       blood_quantum: :blood_quantum, tribe_quantum: :tribe_quantum,
                       enrollment_number: :enrollment_number }.freeze
      QUANTUM = %r{\A(FULL|UNKNOWN|NONE|\d{1,3}/\d{1,4})\z}

      UPDATE_NAMES.each_key { |field| attribute field, :string }

      validates :eligibility_status, inclusion: { in: STATUSES.keys, message: "must be one of RPMS's statuses" }
      validates :classification_ien, presence: true
      validates :tribe_ien, presence: true
      validates :blood_quantum, :tribe_quantum, format: { with: QUANTUM, message: "must be a fraction like 1/4, or FULL, UNKNOWN or NONE" },
                                                allow_blank: true
      validates :enrollment_number, length: { maximum: 12 }, allow_blank: true

      HUMAN_NAMES = { "eligibility_status" => "Eligibility", "classification_ien" => "Classification",
                      "tribe_ien" => "Tribe of membership", "blood_quantum" => "Indian blood quantum",
                      "tribe_quantum" => "Tribe quantum", "enrollment_number" => "Enrollment number" }.freeze

      def self.human_attribute_name(attribute, options = {})
        HUMAN_NAMES.fetch(attribute.to_s) { super }
      end

      # The form, filled from RpmsRpc::Tribal.enrollment.
      def self.from_enrollment(enrollment)
        new(eligibility_status: enrollment[:eligibility_status], classification_ien: enrollment[:classification_ien],
            tribe_ien: enrollment[:tribe_ien], blood_quantum: enrollment[:indian_blood_quantum],
            tribe_quantum: enrollment[:tribe_quantum], enrollment_number: enrollment[:enrollment_number])
      end

      def initialize(attrs = {})
        super
        UPDATE_NAMES.each_key { |field| public_send("#{field}=", public_send(field).to_s.strip.upcase.presence) }
      end

      # The Registration.update attributes that differ from what RPMS holds.
      # An emptied quantum or number is sent as "", which clears it.
      def changes_from(current)
        UPDATE_NAMES.each_with_object({}) do |(field, name), out|
          value = public_send(field).to_s
          out[name] = value unless value == current.public_send(field).to_s
        end
      end
    end
  end
end
