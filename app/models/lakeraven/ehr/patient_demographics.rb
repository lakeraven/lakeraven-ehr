# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the front desk corrects about a registered patient (rpms-ux S-REG-20):
    # the name's spelling, date of birth, sex, marital status, religion, place of
    # birth, employer and employment status, and the social security number.
    #
    # The rules here are the ones BPRM's ChangeDemographicsCommandValidator
    # applies before it saves (date of birth after 1870 and not in the future, a
    # birth city of 2 to 20 letters, an employment status whenever there is an
    # employer). Everything else is RPMS's: AG checks the name, the SSN and the
    # date of birth again before it files (RpmsRpc::Patient.update), and its
    # refusal is shown as it is.
    class PatientDemographics
      include ActiveModel::Model
      include ActiveModel::Attributes
      include SiteRequiredFields

      EARLIEST_DOB = Date.new(1871, 1, 1)
      NAME_FORMAT = /\A[A-Z][A-Z' -]*,[A-Z][A-Z' -]*\z/
      # AG's Personal Detail window's choices for EMPLOYMENT STATUS, IHS PATIENT
      # (9000001) field .21 (#9009068.3 entry 1, parameter 18), in the clerk's words.
      EMPLOYMENT_STATUSES = {
        "FULL-TIME" => "Full-time", "PART-TIME" => "Part-time", "UNEMPLOYED" => "Unemployed",
        "SELF EMPLOYED" => "Self-employed", "RETIRED" => "Retired", "ACTIVE MILITARY DUTY" => "Active military duty",
        "UNKNOWN" => "Unknown"
      }.freeze
      # What the form's fields send to RpmsRpc::Patient.update, by attribute.
      FIELDS = %i[name dob sex marital_status religion birth_city birth_state employer employment_status].freeze

      attribute :name, :string
      attribute :dob, :date
      attribute :sex, :string
      attribute :marital_status, :string
      attribute :religion, :string
      attribute :birth_city, :string
      attribute :birth_state, :string
      attribute :employer, :string
      attribute :employment_status, :string
      # A new number only: the number on file is never sent back to the form.
      attribute :ssn, :string

      # The fields a site may make mandatory in RPMS (#980), IHS PATIENT
      # (9000001) .19 EMPLOYER NAME and .21 EMPLOYMENT STATUS. AG asks the
      # employer as required only of a patient who works full-time or
      # part-time (AGED2), and so does this form.
      site_required employer: [ "9000001", "EMPLOYER NAME" ], employment_status: [ "9000001", "EMPLOYMENT STATUS" ]
      EMPLOYED = %w[FULL-TIME PART-TIME].freeze

      validates :name, presence: true
      validates :name, format: { with: NAME_FORMAT, message: "must be LAST,FIRST MIDDLE" }, length: { in: 3..30 }, allow_blank: true
      validates :sex, inclusion: { in: %w[M F], message: "must be male or female" }
      validates :dob, presence: true
      validate :dob_in_range
      validates :birth_city, length: { in: 2..20, message: "must be 2 to 20 letters" }, allow_blank: true
      validates :employment_status, presence: { message: "is required when there is an employer" }, if: -> { employer.present? }
      validates :employment_status, inclusion: { in: EMPLOYMENT_STATUSES.keys }, allow_blank: true
      validates :ssn, format: { with: /\A\d{9}\z/, message: "must be nine digits" }, allow_blank: true

      # The form, filled from RpmsRpc::Patient.registration_record.
      def self.from_record(record)
        new(name: record[:name], dob: record[:dob], sex: internal(record[:sex]),
            marital_status: internal(record[:marital_status]), religion: internal(record[:religion]),
            birth_city: record[:birth_city], birth_state: internal(record[:birth_state]),
            employer: internal(record[:employer]), employment_status: record.dig(:employment_status, :external))
      end

      def self.internal(pair) = pair.is_a?(Hash) ? pair[:internal] : pair

      def initialize(attrs = {})
        super
        self.name = name.to_s.strip.upcase.squeeze(" ").presence
        self.birth_city = birth_city.to_s.strip.upcase.presence
        self.ssn = ssn.to_s.delete("-").strip.presence
      end

      # The attributes that differ from what RPMS holds, as RpmsRpc::Patient.update
      # takes them. An emptied field is sent as "", which clears it.
      def changes_from(current)
        changed = FIELDS.each_with_object({}) do |field, out|
          value = public_send(field)
          out[field] = value.to_s unless value.to_s == current.public_send(field).to_s
        end
        changed[:dob] = dob if changed.key?(:dob)
        changed[:ssn] = ssn if ssn.present?
        changed
      end

      private

      def site_required_blank?(attribute)
        return false if attribute == :employer && !EMPLOYED.include?(employment_status)

        super
      end

      def dob_in_range
        return if dob.nil?

        errors.add(:dob, "must be after Dec 31, 1870") if dob < EARLIEST_DOB
        errors.add(:dob, "cannot be in the future") if dob > Date.current
      end
    end
  end
end
