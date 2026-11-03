# frozen_string_literal: true

require "digest"

module Lakeraven
  module EHR
    # What the front desk enters to register a new patient (rpms-ux S-REG-02).
    #
    # These checks only make sure the entry is well formed and names the field
    # that is not. Whether the patient may be filed, including whether someone
    # like them is already on file, is decided by RPMS through
    # RpmsRpc::Patient.register (its candidate lookup, then AG's own add).
    class PatientRegistration
      include ActiveModel::Model
      include ActiveModel::Attributes

      EARLIEST_DOB = Date.new(1871, 1, 1)
      # LAST,FIRST MIDDLE, as RPMS files a name: upper-case letters, spaces,
      # hyphens and apostrophes, and exactly one comma.
      NAME_FORMAT = /\A[A-Z][A-Z' -]*,[A-Z][A-Z' -]*\z/
      # PATIENT .0906 PSEUDO SSN REASON, the set RPMS keeps (^DD(2,.0906)). Whether a
      # reason is needed, and whether an SSN may go with one, is AG's own check
      # (RpmsRpc::Patient.register runs it), not this model's.
      NO_SSN_REASONS = { "R" => "Refused to provide", "S" => "SSN unknown, follow-up required", "N" => "No SSN assigned" }.freeze

      attribute :name, :string
      attribute :sex, :string
      attribute :dob, :date
      attribute :ssn, :string
      attribute :no_ssn_reason, :string
      attribute :tribe_ien, :integer
      attribute :community_ien, :integer

      validates :name, presence: true
      validates :name, format: { with: NAME_FORMAT, message: "must be LAST,FIRST MIDDLE" }, length: { in: 3..30 }, allow_blank: true
      validates :sex, inclusion: { in: %w[M F], message: "must be male or female" }
      validates :dob, presence: true
      validate :dob_in_range
      validates :ssn, format: { with: /\A\d{9}\z/, message: "must be nine digits" }, allow_blank: true
      validates :no_ssn_reason, inclusion: { in: NO_SSN_REASONS.keys, message: "is not one of RPMS's reasons" }, allow_blank: true
      validates :tribe_ien, presence: { message: "of membership is required" }
      validates :community_ien, presence: { message: "of residence is required" }

      def initialize(attrs = {})
        super
        self.name = name.to_s.strip.upcase.squeeze(" ").presence
        self.ssn = ssn.to_s.delete("-").strip.presence
      end

      # What RpmsRpc::Patient.register takes. The community dates from birth:
      # the front desk records where the patient lives, not when they moved.
      def register_attrs
        attrs = { name: name, sex: sex, dob: dob, ssn: ssn.to_s, tribe: tribe_ien, community_ien: community_ien, community_since: :birth }
        no_ssn_reason.present? ? attrs.merge(no_ssn_reason: no_ssn_reason) : attrs
      end

      # One value for exactly these details, so a confirmation the clerk gave
      # for one entry cannot be replayed against another.
      def digest
        Digest::SHA256.hexdigest([ name, sex, dob&.iso8601, ssn, tribe_ien, community_ien ].join("|"))
      end

      private

      def dob_in_range
        return if dob.nil?

        errors.add(:dob, "cannot be in the future") if dob > Date.current
        errors.add(:dob, "cannot be before 1871") if dob < EARLIEST_DOB
      end
    end
  end
end
