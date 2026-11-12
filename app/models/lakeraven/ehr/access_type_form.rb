# frozen_string_literal: true

module Lakeraven
  module EHR
    # An access type as a scheduling supervisor defines it (rpms-ux S-SCH-17):
    # a name, a colour, and whether it is inactive or prevents access. Filed in
    # BSDX ACCESS TYPE (#9002018.35) by RpmsRpc::SchedulingMaintenance. The
    # name rule is BPRM's (3 to 30 characters); RPMS refuses a second type of
    # the same name.
    class AccessTypeForm
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :integer
      attribute :name, :string
      attribute :color, :string, default: "#4A90D9"
      attribute :inactive, :boolean, default: false
      attribute :prevent_access, :boolean, default: false

      validates :name, presence: true, length: { minimum: 3, maximum: 30 }
      validates :name, format: { without: /[|^]/, message: "cannot contain | or ^" }
      validates :color, format: { with: /\A#\h{6}\z/, message: "must be a colour such as #4A90D9" }

      def self.from_rpms(type)
        new(type.slice(:id, :name, :inactive, :prevent_access).merge(color: type[:color] || "#4A90D9"))
      end

      def self.human_attribute_name(attribute, options = {})
        { name: "Name", color: "Colour", prevent_access: "Prevent access" }.fetch(attribute.to_sym) { super }
      end

      def persisted? = id.to_i.positive?

      def name = super.to_s.strip.upcase.presence
    end
  end
end
