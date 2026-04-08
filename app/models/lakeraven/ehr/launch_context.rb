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
      validates :expires_at, presence: true

      scope :active, -> { where("expires_at > ?", Time.current) }

      # Mint a new launch context. Returns the persisted record so the
      # caller can read its launch_token to embed in a redirect URL.
      #
      #   ctx = Lakeraven::EHR::LaunchContext.mint(
      #     tenant_identifier: "tnt_test",
      #     patient_identifier: "pt_01H...",
      #     facility_identifier: "fac_main"
      #   )
      #   redirect_to "https://app.example.com/launch?launch=#{ctx.launch_token}&iss=..."
      def self.mint(tenant_identifier:, patient_identifier:, facility_identifier: nil, encounter_identifier: nil, ttl: DEFAULT_TTL)
        create!(
          launch_token: generate_launch_token,
          tenant_identifier: tenant_identifier,
          patient_identifier: patient_identifier,
          facility_identifier: facility_identifier,
          encounter_identifier: encounter_identifier,
          expires_at: Time.current + ttl
        )
      end

      # Resolve a launch token to its context, or nil if missing/expired.
      def self.resolve(launch_token)
        return nil if launch_token.nil? || launch_token.empty?
        active.find_by(launch_token: launch_token)
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
