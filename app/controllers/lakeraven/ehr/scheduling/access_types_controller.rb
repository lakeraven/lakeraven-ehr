# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # The access types a clinic's hours are divided into (rpms-ux S-SCH-17):
      # listed, added, changed and inactivated by a scheduling supervisor, as in
      # BPRM's table maintenance (SDZSUP, S-SCH-17.5). An access type that
      # prevents access takes no booking (S-SCH-17.2, AppointmentBookingGateway).
      class AccessTypesController < BaseController
        rate_limit only: %i[index new create edit update]

        before_action :require_supervisor!
        before_action :load_access_type!, only: %i[edit update]

        # GET /scheduling/access_types
        def index
          @access_types = SchedulingTablesGateway.access_types
          @notice = flash[:notice]
        end

        # GET /scheduling/access_types/new
        def new
          @form = AccessTypeForm.new
        end

        # POST /scheduling/access_types
        def create
          @form = AccessTypeForm.new(form_params.except(:id))
          save(:new)
        end

        # GET /scheduling/access_types/:id/edit
        def edit
          @form = AccessTypeForm.from_rpms(@access_type)
        end

        # POST /scheduling/access_types/:id
        def update
          @form = AccessTypeForm.new(form_params.merge(id: @access_type[:id]))
          save(:edit)
        end

        private

        def save(view)
          return render(view, status: :unprocessable_content) unless @form.valid?

          result = SchedulingTablesGateway.save_access_type(@form)
          case result.status
          when :saved
            flash[:notice] = "Access type #{@form.name} saved."
            redirect_to scheduling_access_types_path
          when :refused
            flash.now[:alert] = "RPMS did not save the access type: #{result.message}"
            render view, status: :unprocessable_content
          else
            flash.now[:alert] = "RPMS did not confirm the change. Check the access types before saving again."
            render view, status: :service_unavailable
          end
        end

        def require_supervisor!
          return if supervisor?

          render plain: "Changing access types takes the scheduling supervisor key (SDZSUP)", status: :forbidden
        end

        def load_access_type!
          @access_type = SchedulingTablesGateway.access_type(params[:id])
          render plain: "No such access type", status: :not_found unless @access_type
        end

        def form_params
          params.fetch(:access_type, {}).permit(:name, :color, :inactive, :prevent_access).to_h.symbolize_keys
        end
      end
    end
  end
end
