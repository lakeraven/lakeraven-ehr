# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the front desk enters to register a new patient (rpms-ux S-REG-02),
    # and the rule that a required value missing refuses the registration and
    # names the value (S-REG-02.2) before anything reaches the broker.
    class PatientRegistration
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :name, :string
      attribute :sex, :string
      attribute :dob, :date
      attribute :ssn, :string
      attribute :tribe_ien, :string
      attribute :community, :string

      validates :name, :sex, :dob, :tribe_ien, :community, presence: true
      validates :sex, inclusion: { in: %w[M F] }, allow_blank: true
      validates :name, format: { with: /\A[^,^]+,[^,^]+\z/, message: "must be LAST,FIRST" }, allow_blank: true
      validates :ssn, format: { with: /\A\d{3}-?\d{2}-?\d{4}\z/, message: "must be nine digits" }, allow_blank: true

      attr_reader :result

      # A refusal names the value as the clerk sees it on the form.
      HUMAN_NAMES = {
        "name" => "Name", "sex" => "Sex", "dob" => "Date of birth", "ssn" => "Social security number",
        "tribe_ien" => "Tribe of membership", "community" => "Community of residence"
      }.freeze

      def self.human_attribute_name(attribute, options = {})
        HUMAN_NAMES.fetch(attribute.to_s) { super }
      end

      def register(gateway: PatientRegistrationGateway)
        return false unless valid?

        @result = gateway.register(
          name: name.strip.upcase, sex: sex, dob: dob, ssn: ssn.to_s.delete("-").presence,
          tribe_ien: tribe_ien, community: community.strip.upcase
        )
        return true if @result[:success]

        errors.add(:base, @result[:error])
        false
      end

      def dfn = result&.dig(:dfn)
      def hrn = result&.dig(:hrn)
      def warnings = Array(result&.dig(:warnings))
    end
  end
end
