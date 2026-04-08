# frozen_string_literal: true

require "securerandom"

module Lakeraven
  module EHR
    # Persistent SMART EHR launch context.
    #
    # When the host application initiates an EHR launch, it mints a
    # LaunchContext that binds a patient (and optionally an encounter)
    # to an opaque launch token. The token is then passed through the
    # OAuth authorize → token round-trip and read by the custom
    # tokens controller, which embeds the patient identifier into the
    # token response per the SMART App Launch spec.
    #
    # Reference: http://hl7.org/fhir/smart-app-launch/app-launch.html
    class LaunchContext < ApplicationRecord
      # Default lifetime — long enough for the launch to complete the
      # OAuth dance, short enough that an abandoned launch doesn't
      # leave a stale binding lying around.
      DEFAULT_TTL = 10.minutes

      validates :launch_token, presence: true, uniqueness: true
      validates :patient_identifier, presence: true
      validates :tenant_identifier, presence: true
      validates :oauth_application_uid, presence: true
      validates :expires_at, presence: true

      scope :active, -> { where("expires_at > ?", Time.current).where(consumed_at: nil) }

      # Mint a new launch context. Returns the persisted record so the
      # caller can read its launch_token to embed in a redirect URL.
      #
      #   ctx = Lakeraven::EHR::LaunchContext.mint(
      #     tenant_identifier: "tnt_test",
      #     oauth_application_uid: doorkeeper_app.uid,
      #     patient_identifier: "pt_01H...",
      #     facility_identifier: "fac_main"
      #   )
      #   redirect_to "https://app.example.com/launch?launch=#{ctx.launch_token}&iss=..."
      #
      # oauth_application_uid binds the launch token to a specific
      # SMART app — only requests authenticated as that client_id can
      # redeem the token. Without this, a leaked launch could be
      # replayed by any other registered client.
      def self.mint(tenant_identifier:, oauth_application_uid:, patient_identifier:, facility_identifier: nil, encounter_identifier: nil, ttl: DEFAULT_TTL)
        create!(
          launch_token: generate_launch_token,
          tenant_identifier: tenant_identifier,
          oauth_application_uid: oauth_application_uid,
          patient_identifier: patient_identifier,
          facility_identifier: facility_identifier,
          encounter_identifier: encounter_identifier,
          expires_at: Time.current + ttl
        )
      end

      # Resolve a launch token, or nil if missing, expired, already
      # consumed, bound to a different tenant, or bound to a different
      # OAuth client.
      #
      # Per ADR 0003 the caller MUST supply tenant_identifier — a
      # launch token minted by tenant A can't be replayed inside
      # tenant B's OAuth flow.
      #
      # Per the launch-token-binding finding on PR #5, the caller MUST
      # also supply oauth_application_uid (the client_id from the
      # token request) — a launch token minted for app X can't be
      # redeemed by app Y.
      def self.resolve(launch_token, tenant_identifier:, oauth_application_uid:)
        return nil if launch_token.nil? || launch_token.to_s.empty?
        return nil if tenant_identifier.nil? || tenant_identifier.to_s.empty?
        return nil if oauth_application_uid.nil? || oauth_application_uid.to_s.empty?
        active.find_by(
          launch_token: launch_token,
          tenant_identifier: tenant_identifier,
          oauth_application_uid: oauth_application_uid
        )
      end

      # Mark this context as consumed. Returns true if this call
      # actually flipped the bit (single-use guarantee), false if a
      # parallel request beat us to it.
      #
      # The check is atomic: a single SQL UPDATE with a
      # `consumed_at IS NULL` predicate. Two concurrent redemptions
      # of the same launch token will see exactly one rows-affected
      # count of 1; the other gets 0 and returns false.
      def consume!
        rows = self.class
          .where(id: id, consumed_at: nil)
          .update_all(consumed_at: Time.current)
        if rows == 1
          reload
          true
        else
          false
        end
      end

      def expired?
        expires_at <= Time.current
      end

      def self.generate_launch_token
        # 32 hex chars of randomness — sufficient entropy that an
        # attacker can't guess valid tokens within their TTL window.
        "lc_#{SecureRandom.hex(16)}"
      end
    end
  end
end
