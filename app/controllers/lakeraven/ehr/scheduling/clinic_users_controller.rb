# frozen_string_literal: true

module Lakeraven
  module EHR
    module Scheduling
      # Read-only administration view. Authorization is enforced before either
      # the resource or its user directory is read; no rights are changed here.
      class ClinicUsersController < BaseController
        rate_limit only: :index
        before_action -> { require_capability!("scheduling.supervise") }
        before_action :load_resource!
        before_action :require_clinic!
        before_action :validate_query!

        def index
          @directory = ClinicUsersGateway.read(@resource, query: @query)
          render :index, status: :service_unavailable if @directory.status == :unavailable
        end

        private

        def require_clinic!
          return if @resource[:hospital_location_id].to_i.positive?

          render plain: "This resource is not a clinic in RPMS", status: :not_found
        end

        def validate_query!
          query = params[:q]
          if !query.nil? && (!query.is_a?(String) || query.length > 100)
            render plain: "Search must be text of at most 100 characters", status: :bad_request
          else
            @query = query.to_s.strip
          end
        end
      end
    end
  end
end
