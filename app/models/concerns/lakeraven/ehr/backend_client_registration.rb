# frozen_string_literal: true

module Lakeraven
  module EHR
    # Registration-time transport rules for backend client JWKS URLs, mixed
    # into Doorkeeper::Application by the engine. A jwks_uri must be HTTPS,
    # and a literal IP host must be public — loopback/private/link-local
    # registrations are refused outright (SSRF / key-substitution hardening;
    # hostname DNS answers are re-vetted at every fetch by ClientJwks, where
    # a registration-time check alone would be TOCTOU).
    module BackendClientRegistration
      extend ActiveSupport::Concern

      included do
        validate :jwks_uri_transport_acceptable, if: -> { jwks_uri.present? }
      end

      private

      def jwks_uri_transport_acceptable
        return if ClientJwks.acceptable_uri?(jwks_uri)

        errors.add(:jwks_uri, "must be an https URL on a publicly routable host")
      end
    end
  end
end
