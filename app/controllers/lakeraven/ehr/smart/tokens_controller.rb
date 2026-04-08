# frozen_string_literal: true

module Lakeraven
  module EHR
    module Smart
      # Custom OAuth token controller that adds SMART launch context
      # (patient + encounter) to the token response when a `launch`
      # parameter is supplied.
      #
      # The host application mints a Lakeraven::EHR::LaunchContext via
      # LaunchContext.mint(...) before redirecting the user-agent to
      # the SMART app's launch URL. The app then includes the
      # `launch` parameter on the eventual /oauth/token request, and
      # this controller resolves it back to the bound patient/encounter
      # and merges those identifiers into the JSON response per the
      # SMART App Launch spec.
      #
      # Reference: http://hl7.org/fhir/smart-app-launch/scopes-and-launch-context.html
      class TokensController < ::Doorkeeper::TokensController
        def create
          super
          merge_launch_context!
        end

        private

        def merge_launch_context!
          return unless successful_token_response?
          launch_token = params[:launch]
          return if launch_token.blank?

          # Resolve the tenant from the configured resolver (subdomain,
          # header, or whatever the host app maps). A launch token
          # bound to tenant A is only redeemable when the request
          # arrives on tenant A's surface — per ADR 0003.
          tenant_identifier = Lakeraven::EHR.configuration.tenant_resolver.call(request)
          return if tenant_identifier.nil? || tenant_identifier.to_s.empty?

          context = LaunchContext.resolve(launch_token, tenant_identifier: tenant_identifier)
          return unless context

          body = parsed_response_body
          body["patient"] = context.patient_identifier if context.patient_identifier
          body["encounter"] = context.encounter_identifier if context.encounter_identifier
          self.response_body = body.to_json
        end

        def successful_token_response?
          status = response.respond_to?(:status) ? response.status : self.status
          status == 200 || status == :ok
        end

        def parsed_response_body
          raw = response_body
          raw = raw.first if raw.is_a?(Array)
          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
