# frozen_string_literal: true

module Lakeraven
  module EHR
    # One coverage the front desk records for billing (rpms-ux S-REG-03.1):
    # Medicaid, Medicare or a private policy. These checks only make sure the
    # entry is well formed; AG decides whether it files (CoverageGateway.add).
    class CoverageEntry
      include ActiveModel::Model
      include ActiveModel::Attributes

      KINDS = %w[medicaid medicare private].freeze
      # MEDICARE ELIGIBILITY (#9000003.11) .03 COVERAGE TYPE.
      MEDICARE_PARTS = { "A" => "Part A (hospital)", "B" => "Part B (medical)", "D" => "Part D (drugs)" }.freeze

      attribute :kind, :string
      attribute :number, :string
      attribute :starts_on, :date
      attribute :ends_on, :date
      attribute :state_ien, :integer
      attribute :part, :string
      attribute :insurer_ien, :integer
      attribute :policy_holder, :string

      validates :kind, inclusion: { in: KINDS, message: "must be Medicaid, Medicare or private insurance" }
      validates :number, presence: true, length: { maximum: 30 }
      validates :number, format: { with: /\A[A-Z0-9-]+\z/, message: "must be letters and digits" }, allow_blank: true
      validates :starts_on, presence: true
      validate :ends_after_start
      validates :state_ien, presence: { message: "that issued the number is required" }, if: -> { kind == "medicaid" }
      validates :part, inclusion: { in: MEDICARE_PARTS.keys, message: "must be A, B or D" }, if: -> { kind == "medicare" }
      validates :insurer_ien, presence: { message: "is required" }, if: -> { kind == "private" }
      validates :policy_holder, presence: true, if: -> { kind == "private" }
      validates :policy_holder, format: { with: /\A[A-Z][A-Z' -]*,[A-Z][A-Z' -]*\z/, message: "must be LAST,FIRST" },
                                allow_blank: true

      def initialize(attrs = {})
        super
        self.number = number.to_s.strip.upcase.delete(" ").presence
        self.policy_holder = policy_holder.to_s.strip.upcase.squeeze(" ").presence
        self.part = part.to_s.strip.upcase.presence
      end

      # The coverage in the clerk's words: "Medicaid", "Medicare", "Private insurance".
      def label = CoverageGateway::KIND_LABELS.fetch(kind&.to_sym, "Coverage")

      # In a sentence: "the Medicaid coverage", "the private insurance".
      def noun = kind == "private" ? "private insurance" : "#{label} coverage"

      HUMAN_NAMES = {
        "number" => "Member number", "starts_on" => "Covered from date", "ends_on" => "Through date",
        "state_ien" => "State", "part" => "Medicare part", "insurer_ien" => "Insurance company",
        "policy_holder" => "Policy holder"
      }.freeze

      def self.human_attribute_name(attribute, options = {})
        HUMAN_NAMES.fetch(attribute.to_s) { super }
      end

      private

      def ends_after_start
        return unless starts_on && ends_on && ends_on < starts_on

        errors.add(:ends_on, "must be on or after the start date")
      end
    end
  end
end
