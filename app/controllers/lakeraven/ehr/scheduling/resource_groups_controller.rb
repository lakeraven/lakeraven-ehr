# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Resource groups (rpms-ux S-SCH-18): clinics, providers, rooms and
      # equipment scheduled together. Anyone who may open scheduling sees a
      # group's day, its clinics side by side (S-SCH-18.2), each as far as their
      # rights on it let them see; making and changing groups takes SDZSUP, as
      # in BPRM's table maintenance.
      class ResourceGroupsController < BaseController
        rate_limit only: %i[index new create show add_member remove_member]

        before_action :require_supervisor!, only: %i[new create add_member remove_member]
        helper_method :supervisor?
        before_action :load_group!, only: %i[show add_member remove_member]

        # GET /scheduling/resource_groups
        def index
          @groups = SchedulingTablesGateway.resource_groups
          @notice = flash[:notice]
        end

        # GET /scheduling/resource_groups/new
        def new; end

        # POST /scheduling/resource_groups
        def create
          @name = params[:name].to_s.strip
          unless (3..30).cover?(@name.length) && !@name.match?(/[|^]/)
            flash.now[:alert] = "A group's name is 3 to 30 characters, without | or ^."
            return render(:new, status: :unprocessable_content)
          end

          result = SchedulingTablesGateway.save_resource_group(@name)
          return redirect_to(scheduling_resource_group_path(result.id), notice: "Group #{@name.upcase} made. Add its clinics.") if result.saved?

          flash.now[:alert] = result.status == :refused ? "RPMS did not make the group: #{result.message}" : "RPMS did not confirm the group. Check the groups before making it again."
          render :new, status: (result.status == :refused ? :unprocessable_content : :service_unavailable)
        end

        # GET /scheduling/resource_groups/:id?date= : each clinic's day, side by side.
        def show
          @date = parse_date(params[:date])
          resources = AppointmentBookingGateway.resources.index_by { |r| r[:id] }
          @members = @group[:resources].filter_map { |item| [ item, resources[item[:resource_id]] ] if resources[item[:resource_id]] }
          @days = @members.filter_map do |_item, resource|
            next unless visible?(resource)

            day, listed = AppointmentBookingGateway.day(resource, @date)
            [ resource, day, listed.reject { |a| a[:cancelled] } ]
          end
          @access_type_names = AppointmentBookingGateway.access_type_names
          @addable = supervisor? ? resources.values.reject { |r| r[:inactive] || @group[:resources].any? { |i| i[:resource_id] == r[:id] } } : []
          @notice = flash[:notice]
        end

        # POST /scheduling/resource_groups/:id/members
        def add_member
          report(SchedulingTablesGateway.add_member(@group[:id], params[:resource_id]), done: "Clinic added to the group.")
        end

        # POST /scheduling/resource_groups/:id/members/:item_id/remove
        def remove_member
          report(SchedulingTablesGateway.remove_member(@group[:id], params[:item_id]), done: "Clinic taken out of the group.")
        end

        private

        def report(result, done:)
          if result.saved?
            flash[:notice] = done
          else
            flash[:alert] = result.status == :refused ? result.message : "RPMS did not confirm the change. Check the group before trying again."
          end
          redirect_to scheduling_resource_group_path(@group[:id])
        end

        def require_supervisor!
          return if supervisor?

          render plain: "Changing resource groups takes the scheduling supervisor key (SDZSUP)", status: :forbidden
        end

        def load_group!
          @group = SchedulingTablesGateway.resource_group(params[:id])
          render plain: "No such resource group", status: :not_found unless @group
        end
      end
    end
  end
end
