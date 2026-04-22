# frozen_string_literal: true

module Lakeraven
  module EHR
    class SecurityMonitor
      THRESHOLD = 5
      STORM_LIMIT = 10

      attr_reader :incidents

      def initialize(incidents: [])
        @incidents = incidents
      end

      def run(failed_attempts:)
        failed_attempts.group_by { |a| a[:ip_address] }.each do |ip, attempts|
          next if attempts.length <= THRESHOLD
          next if already_tracked?(ip)
          next if incident_storm?

          @incidents << SecurityIncident.new(
            ip_address: ip, incident_type: "brute_force",
            severity: "high", status: "open", created_at: Time.current
          )
        end
      end

      private

      def already_tracked?(ip)
        @incidents.any? { |i| i.ip_address == ip && i.open? }
      end

      def incident_storm?
        @incidents.count { |i| i.incident_type == "brute_force" && i.open? } > STORM_LIMIT
      end
    end
  end
end
