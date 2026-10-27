# frozen_string_literal: true

require "rpms_rpc/api/patient"

module Lakeraven
  module EHR
    module Registration
      # The front desk finds a patient before registering one (rpms-ux S-REG-01).
      #
      # Gated on the keys BPRM's registration screens gate on: one of the
      # registration keys (AGZMENU, AGZMGR, AGZVIEWONLY) or the scheduling menu
      # keys (SDZMENU, SDZSUP). A signed-on user without one is refused.
      class PatientsController < WebController
        VIEW_KEYS = %w[registration_menu registration_manager registration_view_only scheduling_user scheduling_supervisor].freeze

        before_action :require_authentication
        before_action :require_registration_view_key!

        # GET /registration/patients?q=&dob=
        def index
          @query = params[:q].to_s.strip
          @dob = parse_dob(params[:dob])
          @searched = @query.present?
          @matches = @searched ? PatientLookupGateway.find(@query, dob: @dob) : []
        rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
          Rails.logger.error("[registration] patient lookup failed: #{e.class}")
          @lookup_failed = true
          @matches = []
          render :index, status: :service_unavailable
        end

        # GET /registration/patients/:dfn
        def show
          @patient = RpmsRpc::Patient.brief_header(params[:dfn].to_i)
          render :not_found, status: :not_found unless @patient
        end

        private

        def require_registration_view_key!
          held = Array(session[:security_keys])
          head :forbidden unless VIEW_KEYS.any? { |key| held.include?(key) }
        end

        def parse_dob(value)
          Date.iso8601(value.to_s) if value.present?
        rescue Date::Error
          nil
        end
      end
    end
  end
end
