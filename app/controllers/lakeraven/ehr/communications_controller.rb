# frozen_string_literal: true

module Lakeraven
  module EHR
    # Demo prototype (#988; not in the December build, and the FHIR API is not
    # certified). A registered outside app posts what it learned about a
    # referral as a Communication. It is held for staff review with status
    # in-progress and never applied automatically: nothing reaches RPMS until
    # a person confirms it (ReferralFollowUpsController). The app can read it
    # back, including a rejection (#989).
    #
    # POST needs Communication create (system/Communication.c) and the
    # ServiceRequest it is about must be one the token can read. Reading the
    # referral reaches RPMS, so on a deployed stack a backend token answers
    # 503 until #844 gives it an RPMS identity.
    class CommunicationsController < ApplicationController
      rate_limit only: %i[create show]

      before_action :require_service_request_read!, only: :create

      def create
        application = current_token.application
        unless application
          return render_operation_outcome(status: :forbidden, severity: "error", code: "forbidden",
                                          diagnostics: "Only a token issued to a registered app may post a Communication")
        end

        result = AppFollowUpIntake.call(communication_params, application: application,
                                        referrals_for: ->(dfn) { ServiceRequest.for_patient(dfn) })
        if result.error
          return render_operation_outcome(status: :unprocessable_content, severity: "error", code: "invalid",
                                          diagnostics: result.error)
        end

        result.follow_up.save!
        AppFollowUpAudit.record!(result.follow_up, action: "C", what: "held for review")
        response.set_header("Location", "#{request.base_url}#{request.path}/#{result.follow_up.id}")
        render_fhir(result.follow_up.to_fhir, status: :created)
      end

      # The app reads back what became of what it posted. Only the app that
      # posted it can.
      def show
        follow_up = AppFollowUp.find_by(id: params[:id], client_id: current_token.application&.uid)
        return render_not_found("Communication", params[:id]) unless follow_up

        render_fhir(follow_up.to_fhir)
      end

      private

      def require_service_request_read!
        return if can_read?("ServiceRequest")

        render_forbidden("Insufficient scope for reading ServiceRequest")
      end

      def communication_params
        request.request_parameters.presence || JSON.parse(request.raw_post.presence || "{}")
      rescue JSON::ParserError
        {}
      end
    end
  end
end
