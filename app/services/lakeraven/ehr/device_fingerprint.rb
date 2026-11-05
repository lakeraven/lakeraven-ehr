# frozen_string_literal: true

require "digest"

module Lakeraven
  module EHR
    # DeviceFingerprint - Generates device fingerprints from request headers
    #
    # Used for session tracking and anomaly detection (HIPAA session management).
    # Fingerprint is a SHA256 hash of normalized browser characteristics.
    #
    # Ported from the predecessor app DeviceFingerprint.
    class DeviceFingerprint
      LOOKBACK_DAYS = 90

      # Generate a fingerprint from the request
      # Returns first 32 characters of SHA256 hex digest
      def self.generate(request)
        components = [
          normalize(request.user_agent),
          normalize(request.headers["Accept-Language"]),
          normalize(request.headers["Accept-Encoding"])
        ]

        Digest::SHA256.hexdigest(components.join("|"))[0, 32]
      end

      # Check if this device has been seen for this user in the last 90 days
      # @param sessions [Array<Hash>] session records with :duz, :device_fingerprint, :created_at
      def self.known_device?(duz:, fingerprint:, sessions: [])
        cutoff = LOOKBACK_DAYS.days.ago
        sessions.any? do |s|
          s[:duz] == duz &&
            s[:device_fingerprint] == fingerprint &&
            s[:created_at] > cutoff
        end
      end

      # Detect anomalous login: both device AND IP are new
      # @param sessions [Array<Hash>] session records with :duz, :device_fingerprint, :ip_address, :created_at
      def self.anomalous?(duz:, request:, sessions: [])
        fingerprint = generate(request)
        ip = client_address(request)
        cutoff = LOOKBACK_DAYS.days.ago

        device_known = sessions.any? do |s|
          s[:duz] == duz && s[:device_fingerprint] == fingerprint && s[:created_at] > cutoff
        end

        ip_known = sessions.any? do |s|
          s[:duz] == duz && s[:ip_address] == ip && s[:created_at] > cutoff
        end

        !device_known && !ip_known
      end

      def self.normalize(value)
        value.to_s.strip.downcase
      end

      # Rack requests go through ClientIp so trust_forwarded_for applies.
      # A caller that only exposes remote_ip (no header rack) keeps that
      # address.
      def self.client_address(request)
        return ClientIp.resolve(request) if request.respond_to?(:get_header)

        request.remote_ip
      end
      private_class_method :normalize, :client_address
    end
  end
end
