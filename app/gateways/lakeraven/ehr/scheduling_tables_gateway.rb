# frozen_string_literal: true

require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/scheduling_maintenance"

module Lakeraven
  module EHR
    # Scheduling table maintenance (rpms-ux S-SCH-17, S-SCH-18): the access
    # types a clinic's hours are divided into, BSDX ACCESS TYPE (#9002018.35),
    # and the resource groups whose schedules are seen together, BSDX RESOURCE
    # GROUP (#9002018.2). Read with DDR LISTER (SchedulingSetup) and filed
    # through the BSDX add/edit RPCs Windows Scheduling sends
    # (SchedulingMaintenance), so BPRM and Windows Scheduling see the same rows.
    class SchedulingTablesGateway
      # RPMS answered the holidays read, but not with a list of dated rows.
      class UnreadableHolidays < ::RpmsRpc::Error; end

      # status: :saved (id names the row), :refused (message is RPMS's reason),
      # :not_found (a holiday removal named a date with none) or :unknown (RPMS
      # did not answer).
      Result = Data.define(:status, :id, :message) do
        def saved? = status == :saved
      end

      def self.access_types(setup: ::RpmsRpc::SchedulingSetup)
        Array(setup.access_types)
      end

      def self.access_type(id, setup: ::RpmsRpc::SchedulingSetup)
        access_types(setup: setup).find { |t| t[:id] == id.to_i }
      end

      def self.save_access_type(form, maintenance: ::RpmsRpc::SchedulingMaintenance)
        filing do
          outcome(maintenance.save_access_type(id: form.id, name: form.name, inactive: form.inactive,
                                               prevent_access: form.prevent_access, color: form.color.upcase))
        end
      end

      def self.resource_groups(setup: ::RpmsRpc::SchedulingSetup)
        Array(setup.resource_groups)
      end

      def self.resource_group(id, setup: ::RpmsRpc::SchedulingSetup)
        resource_groups(setup: setup).find { |g| g[:id] == id.to_i }
      end

      def self.save_resource_group(name, id: nil, maintenance: ::RpmsRpc::SchedulingMaintenance)
        filing { outcome(maintenance.save_resource_group(id: id, name: name.to_s.strip.upcase)) }
      end

      # Puts a clinic resource in a group; one already there is a refusal.
      def self.add_member(group_id, resource_id, maintenance: ::RpmsRpc::SchedulingMaintenance)
        filing do
          added = maintenance.add_resource_group_member(group_id: group_id, resource_id: resource_id)
          next Result.new(status: :refused, id: nil, message: "That clinic is already in the group.") if added&.dig(:error) == :already_in_group

          outcome(added)
        end
      end

      def self.remove_member(group_id, item_id, maintenance: ::RpmsRpc::SchedulingMaintenance)
        filing { outcome(maintenance.remove_resource_group_member(group_id: group_id, item_id: item_id)) }
      end

      # The site-wide holidays (HOLIDAY #40.5) from today through a year ahead
      # (rpms-ux S-SCH-19). Never cached: the open times must see a change at
      # once. A failed read raises RpmsRpc::Error for the caller to show.
      def self.holidays(setup: ::RpmsRpc::SchedulingSetup)
        today = SiteTime.today
        rows = setup.holidays(start_date: today, end_date: today.next_year)
        unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row[:date].is_a?(Date) }
          raise UnreadableHolidays, "RPMS answered holidays with something other than a list of dated rows"
        end

        rows
      end

      def self.add_holiday(date, name, setup: ::RpmsRpc::SchedulingSetup)
        filing { holiday_outcome(setup.add_holiday(date: date, name: name)) }
      end

      def self.remove_holiday(date, setup: ::RpmsRpc::SchedulingSetup)
        filing { holiday_outcome(setup.remove_holiday(date)) }
      end

      def self.outcome(reply)
        return Result.new(status: :unknown, id: nil, message: nil) unless reply.is_a?(Hash)
        return Result.new(status: :saved, id: reply[:id], message: nil) if reply[:success] == true

        reason = reply[:message].presence || reply[:error]
        return Result.new(status: :unknown, id: nil, message: nil) if reason.blank?
        return Result.new(status: :not_found, id: nil, message: reply[:message]) if reply[:error] == :not_found
        # Only a String is RPMS's reason; a Symbol is the gem's internal code,
        # so a refusal without a message says nothing more.
        return Result.new(status: :refused, id: nil, message: nil) unless reason.is_a?(String)

        Result.new(status: :refused, id: nil, message: reason.sub(/\ABSDX\d+: /, ""))
      end
      private_class_method :outcome

      # rpms-rpc DdrFileman.filer (ddr_fileman.rb) answers a reply with no
      # [Data] line as :filer_failed with this text: the call did not complete,
      # so whether RPMS filed is unknown, not a refusal.
      NO_DATA_MARKER = "no [Data] marker in DDR FILER reply"

      def self.holiday_outcome(reply)
        if reply.is_a?(Hash) && reply[:error] == :filer_failed && reply[:message].to_s.start_with?(NO_DATA_MARKER)
          return Result.new(status: :unknown, id: nil, message: nil)
        end

        outcome(reply)
      end
      private_class_method :holiday_outcome

      # A write that raises may already have filed: its outcome is unknown.
      def self.filing
        yield
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] table maintenance raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, id: nil, message: nil)
      end
      private_class_method :filing
    end
  end
end
