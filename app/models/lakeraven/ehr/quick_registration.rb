# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to register a caller who has no chart, while
    # booking them (rpms-ux S-REG-05): name, sex, date of birth and SSN (or the
    # reason there is none), and a chart number the caller was given, or none,
    # for a temporary one. It is IHS scheduling's mini-registration (option
    # BSDAM MINI REGISTRATION): the front desk completes the registration when
    # the patient arrives.
    #
    # As with PatientRegistration, these checks only make sure the entry is well
    # formed. Whether it files, whether someone like the caller is already on
    # file, and whether the chart number is free, are RPMS's answers, through
    # RpmsRpc::Patient.register.
    class QuickRegistration
      include ActiveModel::Model
      include ActiveModel::Attributes

      # HEALTH RECORD NO. (#9000001.41 .02) takes 1 to 6 digits with no leading
      # zero from a clerk (its input transform and AG's window length), or a
      # temporary T-number, which RPMS assigns.
      CHART_NUMBER_FORMAT = /\A[1-9]\d{0,5}\z/

      attribute :name, :string
      attribute :sex, :string
      attribute :dob, :date
      attribute :ssn, :string
      attribute :no_ssn_reason, :string
      attribute :chart_number, :string

      validates :name, presence: true
      validates :name, format: { with: PatientRegistration::NAME_FORMAT, message: "must be LAST,FIRST MIDDLE" }, length: { in: 3..30 }, allow_blank: true
      validates :sex, inclusion: { in: %w[M F], message: "must be male or female" }
      validates :dob, presence: true
      validate :dob_in_range
      validates :ssn, format: { with: /\A\d{9}\z/, message: "must be nine digits" }, allow_blank: true
      validates :no_ssn_reason, inclusion: { in: PatientRegistration::NO_SSN_REASONS.keys, message: "is not one of RPMS's reasons" }, allow_blank: true
      validates :chart_number, format: { with: CHART_NUMBER_FORMAT, message: "must be up to six digits, not starting with 0" }, allow_blank: true

      def initialize(attrs = {})
        super
        self.name = name.to_s.strip.upcase.squeeze(" ").presence
        self.ssn = ssn.to_s.delete("-").strip.presence
        self.chart_number = chart_number.to_s.strip.presence
      end

      # A chart number was given, rather than asking RPMS for a temporary one.
      def chart_number_given? = chart_number.present?

      # What RpmsRpc::Patient.register takes.
      def register_attrs
        attrs = { name: name, sex: sex, dob: dob, ssn: ssn.to_s }
        attrs[:no_ssn_reason] = no_ssn_reason if no_ssn_reason.present?
        chart_number_given? ? attrs.merge(hrn_source: :given, hrn: chart_number) : attrs.merge(hrn_source: :temporary)
      end

      private

      def dob_in_range
        return if dob.nil?

        errors.add(:dob, "cannot be in the future") if dob > SiteDate.today
        errors.add(:dob, "cannot be before 1871") if dob < PatientRegistration::EARLIEST_DOB
      end
    end
  end
end
