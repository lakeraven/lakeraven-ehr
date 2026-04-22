# frozen_string_literal: true

module Lakeraven
  module EHR
    class SecurityIncident
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ip_address, :string
      attribute :incident_type, :string, default: "brute_force"
      attribute :severity, :string, default: "high"
      attribute :status, :string, default: "open"
      attribute :created_at, :datetime

      def open?
        status == "open"
      end
    end
  end
end
