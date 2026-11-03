# frozen_string_literal: true

module Lakeraven
  module EHR
    # The patient bar's search (rpms-ux S-CHT-01.1, .2, .9): find a patient by
    # name, health record number, date of birth or the last four of the SSN,
    # or pick from the patients you opened before, and open their chart.
    #
    # Reading patients takes the session's Patient read, the chart's own
    # (CIAV VUECENTRIC, SessionScopePolicy). Only a POST searches, so what was
    # typed never travels in a URL (#722).
    class ChartSearchesController < WebController
      include RpmsUnavailableRendering

      before_action :require_authentication
      before_action :require_patient_read!

      # GET /chart_search: the search, and my recent patients.
      def show
        @recent = ChartSearchGateway.recent(session[:duz], tenant: audit_tenant_identifier)
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
        lookup_failed(e)
      end

      # POST /chart_search (q): the search.
      def create
        @query = params[:q].to_s.strip
        @matches = @query.empty? ? [] : ChartSearchGateway.find(@query)
        render :show
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
        lookup_failed(e)
      end

      private

      def require_patient_read!
        return if patient_search_allowed?

        note_audit_denial("browser access refused: no Patient read")
        head :forbidden
      end

      def lookup_failed(error)
        return end_session_for_closed_rpms! if rpms_connection_closed?

        Rails.logger.error("[chart-search] patient lookup failed: #{error.class}")
        @lookup_failed = true
        @matches = []
        render :show, status: :service_unavailable
      end

      # A search reads patients; it names none of them.
      def audit_action = "R"
      def fhir_resource_type = "Patient"
    end
  end
end
