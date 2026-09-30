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
        validate :organization_id_is_immutable, on: :update
      end

      private

      # ADR 0007: organization_id is an IMMUTABLE foreign key to the tenant.
      # Immutability is not cosmetic — it is what makes the token's tenant
      # discoverable as token.application.organization_id without stamping a
      # copy onto the token itself. If this rule is ever relaxed, that
      # decision has to be revisited in the same change.
      def organization_id_is_immutable
        return unless organization_id_changed?
        # Settable ONCE. A nil -> value write is the initial binding, which is
        # how a client acquires its tenant; only value -> other-value is the
        # change ADR 0007 forbids.
        return if organization_id_was.blank?

        errors.add(:organization_id, "cannot be changed")
      end

      def jwks_uri_transport_acceptable
        return if ClientJwks.acceptable_uri?(jwks_uri)

        errors.add(:jwks_uri, "must be an https URL on a publicly routable host")
      end
    end
  end
end
