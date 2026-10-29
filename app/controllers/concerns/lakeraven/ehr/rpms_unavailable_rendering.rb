# frozen_string_literal: true

module Lakeraven
  module EHR
    # A page that reads RPMS says so when RPMS does not answer, rather than
    # failing with a 500 (#724). Any gem error that reaches the controller is
    # rendered here: a refusal (RpcRefusedError, RPMS served the RPC but not to
    # this user) as 403 with RPMS's own reason, anything else as 503.
    #
    # Writes do not land here: their gateways answer "outcome unknown" for an
    # error mid-call, because the write may already have filed.
    module RpmsUnavailableRendering
      extend ActiveSupport::Concern

      included do
        rescue_from ::RpmsRpc::Error, with: :render_rpms_unavailable
      end

      private

      def render_rpms_unavailable(error)
        return end_session_for_closed_rpms! if rpms_connection_closed?

        Rails.logger.error("[rpms] #{controller_path}##{action_name} raised #{error.class}")
        @rpms_refusal = error.message if error.is_a?(::RpmsRpc::Client::RpcRefusedError)
        render "lakeraven/ehr/shared/rpms_unavailable", status: (@rpms_refusal ? :forbidden : :service_unavailable)
      end
    end
  end
end
