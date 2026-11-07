# frozen_string_literal: true

module Lakeraven
  module EHR
    # The EHR side of a SMART EHR launch (#839): a signed-in user opens a
    # patient in a registered app. The engine mints a launch context (the
    # patient, an encounter when one is given, the user) and sends the browser
    # to the app's registered launch URI with `iss` (this FHIR server) and
    # `launch` (the context). The app then sends the user to authorize with
    # that `launch`, and only this user can authorize with it, once, within
    # LaunchContext::DEFAULT_TTL.
    #
    # GET /smart/launch?patient=DFN lists the apps registered with a launch
    # URI; POST launches one. Opening a patient takes the user's own Patient
    # read (ADR 0010), as the chart does. A launch only ever goes to the
    # launch URI the app registered.
    class SmartLaunchController < WebController
      include SmartEndpoints
      include RateLimitable

      # client_id on this route is an oracle for registered apps (#498).
      rate_limit only: %i[show create]

      DFN = /\A\d{1,18}\z/

      before_action :require_authentication
      before_action :require_patient_read!
      before_action :load_patient

      def show
        @apps = Doorkeeper::Application.where.not(launch_uri: [ nil, "" ]).order(:name)
                                       .select { |app| LaunchClient.launch_client?(app) }
      end

      def create
        app = LaunchClient.find(params[:client_id].to_s)
        return head(:not_found) unless app && app.launch_uri.present?

        context = LaunchContext.mint(
          oauth_application_uid: app.uid,
          patient_dfn: @dfn,
          encounter_id: launch_encounter_id,
          duz: session[:duz].to_s
        )
        redirect_to launch_url(app, context), allow_other_host: true
      end

      private

      # A launch names a visit of its patient; the token names that Encounter by
      # the id a read takes, so the app can fetch it.
      def launch_encounter_id
        visit = params[:encounter].to_s
        FHIR::PatientScopedId.build(@dfn, visit) if visit.match?(DFN)
      end

      def require_patient_read!
        return if SmartScope.permits?(session_token_scopes, "Patient", "r")

        note_audit_denial("browser access refused: no Patient read")
        render "lakeraven/ehr/shared/forbidden", formats: :html, status: :forbidden
      end

      def load_patient
        @dfn = params[:patient].to_s
        return head(:not_found) unless @dfn.match?(DFN)

        @patient = ChartSearchGateway.one(@dfn)
        head(:not_found) unless @patient
      end

      def launch_url(app, context)
        uri = URI.parse(app.launch_uri)
        query = URI.decode_www_form(uri.query.to_s) + [ [ "iss", smart_fhir_base_url ], [ "launch", context.launch_token ] ]
        uri.query = URI.encode_www_form(query)
        uri.to_s
      end

      def session_token_scopes
        Doorkeeper::AccessToken.by_token(session[:smart_token].to_s)&.scopes.to_s
      end

      def audit_action = "R"
      def fhir_resource_type = "Patient"
    end
  end
end
