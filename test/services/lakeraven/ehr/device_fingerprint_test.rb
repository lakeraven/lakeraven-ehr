# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DeviceFingerprintTest < ActiveSupport::TestCase
      # =============================================================================
      # GENERATE
      # =============================================================================

      test "generate produces a 32-character hex string" do
        request = mock_request
        fingerprint = DeviceFingerprint.generate(request)

        assert_equal 32, fingerprint.length
        assert_match(/\A[0-9a-f]{32}\z/, fingerprint)
      end

      test "generate is deterministic for the same inputs" do
        request = mock_request
        first = DeviceFingerprint.generate(request)
        second = DeviceFingerprint.generate(request)

        assert_equal first, second
      end

      test "generate produces different fingerprints for different user agents" do
        request_chrome = mock_request(user_agent: "Mozilla/5.0 Chrome/120")
        request_firefox = mock_request(user_agent: "Mozilla/5.0 Firefox/120")

        refute_equal DeviceFingerprint.generate(request_chrome),
                     DeviceFingerprint.generate(request_firefox)
      end

      test "generate produces different fingerprints for different Accept-Language" do
        request_en = mock_request(accept_language: "en-US")
        request_es = mock_request(accept_language: "es-MX")

        refute_equal DeviceFingerprint.generate(request_en),
                     DeviceFingerprint.generate(request_es)
      end

      test "generate normalizes case" do
        request_upper = mock_request(user_agent: "Mozilla/5.0 CHROME")
        request_lower = mock_request(user_agent: "Mozilla/5.0 chrome")

        assert_equal DeviceFingerprint.generate(request_upper),
                     DeviceFingerprint.generate(request_lower)
      end

      # =============================================================================
      # KNOWN DEVICE
      # =============================================================================

      test "known_device? returns true when device seen recently" do
        sessions = [
          { duz: "100", device_fingerprint: "abc123", ip_address: "10.0.0.1", created_at: 30.days.ago }
        ]

        assert DeviceFingerprint.known_device?(duz: "100", fingerprint: "abc123", sessions: sessions)
      end

      test "known_device? returns false for unknown device" do
        refute DeviceFingerprint.known_device?(duz: "100", fingerprint: "never-seen", sessions: [])
      end

      test "known_device? returns false for device older than 90 days" do
        sessions = [
          { duz: "100", device_fingerprint: "old-device", ip_address: "10.0.0.1", created_at: 91.days.ago }
        ]

        refute DeviceFingerprint.known_device?(duz: "100", fingerprint: "old-device", sessions: sessions)
      end

      # =============================================================================
      # ANOMALOUS
      # =============================================================================

      test "anomalous? returns true when both device and IP are new" do
        request = mock_request(remote_ip: "10.0.0.99")

        assert DeviceFingerprint.anomalous?(duz: "200", request: request, sessions: [])
      end

      test "anomalous? returns false when device is known" do
        request = mock_request(remote_ip: "10.0.0.99")
        fingerprint = DeviceFingerprint.generate(request)

        sessions = [
          { duz: "200", device_fingerprint: fingerprint, ip_address: "192.168.1.1", created_at: 10.days.ago }
        ]

        refute DeviceFingerprint.anomalous?(duz: "200", request: request, sessions: sessions)
      end

      test "anomalous? returns false when IP is known" do
        request = mock_request(remote_ip: "192.168.1.50")

        sessions = [
          { duz: "200", device_fingerprint: "different-fp", ip_address: "192.168.1.50", created_at: 10.days.ago }
        ]

        refute DeviceFingerprint.anomalous?(duz: "200", request: request, sessions: sessions)
      end

      private

      FakeRequest = Struct.new(:user_agent, :headers, :remote_ip, keyword_init: true)

      def mock_request(user_agent: "Mozilla/5.0 Test", accept_language: "en-US", accept_encoding: "gzip", remote_ip: "127.0.0.1")
        FakeRequest.new(
          user_agent: user_agent,
          headers: {
            "Accept-Language" => accept_language,
            "Accept-Encoding" => accept_encoding
          },
          remote_ip: remote_ip
        )
      end
    end
  end
end
