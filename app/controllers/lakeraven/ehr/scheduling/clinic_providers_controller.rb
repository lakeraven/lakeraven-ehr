# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Existing clinic providers and the default used at check-in (S-SCH-16).
      class ClinicProvidersController < BaseController
        rate_limit only: %i[index set_default destroy]

        before_action :require_supervisor!, only: %i[set_default destroy]
        before_action :load_resource!
        before_action :require_clinic!
        helper_method :supervisor?

        def index
          @providers = ClinicProvidersGateway.read(@resource)
        end

        def set_default
          change(:default)
        end

        def destroy
          change(:remove)
        end

        private

        def require_supervisor!
          return if supervisor?

          render plain: "Changing clinic providers takes the scheduling supervisor key (SDZSUP)", status: :forbidden
        end

        def require_clinic!
          return if @resource[:hospital_location_id].to_i.positive?

          render plain: "No such clinic resource", status: :not_found
        end

        def change(action)
          case ClinicProvidersGateway.change(@resource, params[:entry_id], action)
          when :missing
            render plain: "No such clinic provider", status: :not_found
          when :saved
            flash[:notice] = action == :default ? "Default provider set." : "Provider removed."
            redirect_to scheduling_clinic_providers_path(@resource[:id])
          else
            flash[:alert] = "RPMS did not confirm the change. Open the provider list again to check it."
            redirect_to scheduling_clinic_providers_path(@resource[:id])
          end
        end
      end
    end
  end
end
