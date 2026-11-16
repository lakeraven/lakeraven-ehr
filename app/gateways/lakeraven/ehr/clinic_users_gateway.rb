# frozen_string_literal: true

require "rpms_rpc/api/scheduling_setup"

module Lakeraven
  module EHR
    # S-SCH-16: inspect existing BSDX RESOURCE USER entries, not providers in
    # HOSPITAL LOCATION. RPMS remains authoritative; every request reads again.
    class ClinicUsersGateway
      Result = Data.define(:status, :users, :total)
      RIGHTS = %i[overbook modify_schedule modify_appointments master_overbook].freeze

      def self.read(resource, query: "", setup: ::RpmsRpc::SchedulingSetup)
        users = setup.resource_users(resource[:id])
        return unavailable unless users.is_a?(Array) && users.all? { |user| valid_user?(user) }

        sorted = users.sort_by { |user| [ user[:name].downcase, user[:name], user[:id] ] }
        matches = sorted.select { |user| user[:name].downcase.include?(query.downcase) }
        Result.new(status: :available, users: matches, total: users.length)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => error
        Rails.logger.error("[scheduling] reading clinic users raised #{error.class}")
        unavailable
      end

      def self.valid_user?(user)
        user.is_a?(Hash) && user[:id].is_a?(Integer) && user[:id].positive? &&
          user[:name].is_a?(String) && RIGHTS.all? { |right| [ true, false ].include?(user[right]) }
      end
      private_class_method :valid_user?

      def self.unavailable = Result.new(status: :unavailable, users: [], total: nil)
      private_class_method :unavailable
    end
  end
end
