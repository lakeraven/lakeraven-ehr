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
      # status: :saved (id names the row), :refused (message is RPMS's reason)
      # or :unknown (RPMS did not answer).
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

      def self.outcome(reply)
        return Result.new(status: :unknown, id: nil, message: nil) if reply.nil?
        return Result.new(status: :saved, id: reply[:id], message: nil) if reply[:success]

        Result.new(status: :refused, id: nil, message: reply[:error].to_s.sub(/\ABSDX\d+: /, ""))
      end
      private_class_method :outcome

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
