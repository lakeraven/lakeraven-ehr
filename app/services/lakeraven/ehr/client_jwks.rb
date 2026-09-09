# frozen_string_literal: true

require "net/http"
require "resolv"
require "ipaddr"

module Lakeraven
  module EHR
    # Fetches a backend client's published JWKS (SMART Backend Services).
    #
    # The client publishes and rotates its keys at a JWKS URL registered on
    # its Doorkeeper application (jwks_uri). A short cache TTL keeps key
    # rotation timely without refetching on every token request.
    #
    # Transport hardening (SSRF / key-substitution): keys are fetched ONLY
    # over HTTPS from hosts that resolve exclusively to public addresses —
    # a JWKS "fetched" from loopback/private/link-local space could be
    # attacker-substituted key material or a server-side request into
    # internal services. Enforced both at registration
    # (BackendClientRegistration) and again at every fetch (DNS answers
    # change; registration-time checks alone are TOCTOU). The connection is
    # pinned to the vetted resolved address so the checked answer is the one
    # dialed. Failures are never cached — a transient JWKS outage must not
    # brown out client auth for a full TTL.
    class ClientJwks
      CACHE_TTL = 5.minutes
      FETCH_TIMEOUT = 5 # seconds

      class << self
        # DNS resolution seam: tests substitute controlled answers so the
        # address checks below still execute. Defaults to real DNS.
        attr_writer :resolver

        def resolver
          @resolver ||= Resolv
        end

        # Returns the parsed JWKS as a symbol-keyed hash ({ keys: [...] }),
        # or nil when the JWKS cannot be fetched or parsed.
        def fetch(jwks_uri)
          return nil if jwks_uri.blank?

          cache_key = "client_jwks/#{jwks_uri}"
          cached = Rails.cache.read(cache_key)
          return cached if cached

          fetched = fetch_uncached(jwks_uri)
          Rails.cache.write(cache_key, fetched, expires_in: CACHE_TTL) if fetched
          fetched
        end

        # True when the URI is acceptable to register and fetch: HTTPS with a
        # host, and any literal IP host must be public. Hostnames pass here;
        # their resolved addresses are vetted at fetch time.
        def acceptable_uri?(jwks_uri)
          uri = URI.parse(jwks_uri.to_s)
          return false unless uri.is_a?(URI::HTTPS) && uri.host.present?

          literal = ip_literal(uri.host)
          literal.nil? || public_address?(literal)
        rescue URI::InvalidURIError
          false
        end

        private

        def fetch_uncached(jwks_uri)
          return nil unless acceptable_uri?(jwks_uri)

          uri = URI.parse(jwks_uri)
          address = vetted_public_address(uri.host)
          return nil unless address

          response = Net::HTTP.start(uri.host, uri.port,
                                     ipaddr: address,
                                     use_ssl: true,
                                     open_timeout: FETCH_TIMEOUT,
                                     read_timeout: FETCH_TIMEOUT) do |http|
            http.get(uri.request_uri)
          end
          return nil unless response.is_a?(Net::HTTPSuccess)

          parsed = JSON.parse(response.body, symbolize_names: true)
          parsed.is_a?(Hash) && parsed[:keys].is_a?(Array) ? parsed : nil
        rescue StandardError
          nil
        end

        # The address to dial: an already-vetted literal, or the host's DNS
        # answers — ALL of which must be public (one private answer poisons
        # the set) — pinned to the first.
        def vetted_public_address(host)
          literal = ip_literal(host)
          return (public_address?(literal) ? literal.to_s : nil) if literal

          addresses = resolver.getaddresses(host).filter_map { |a| ip_literal(a.to_s) }
          return nil if addresses.empty? || !addresses.all? { |a| public_address?(a) }

          addresses.first.to_s
        end

        def ip_literal(host)
          IPAddr.new(host.to_s)
        rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
          nil
        end

        # Special-use ranges that are not loopback/private/link-local but are
        # still never a client's public JWKS infrastructure: carrier-grade
        # NAT (RFC 6598), benchmarking (RFC 2544), multicast, and
        # reserved-for-future-use / broadcast (240.0.0.0/4 includes
        # 255.255.255.255). (Independent security review finding: these fell
        # through the earlier check.)
        SPECIAL_USE_RANGES = [
          IPAddr.new("100.64.0.0/10"),  # carrier-grade NAT
          IPAddr.new("198.18.0.0/15"),  # benchmarking
          IPAddr.new("224.0.0.0/4"),    # IPv4 multicast
          IPAddr.new("240.0.0.0/4"),    # reserved + limited broadcast
          IPAddr.new("ff00::/8")        # IPv6 multicast
        ].freeze

        # Public = not loopback (127/8, ::1), not RFC1918/unique-local
        # (10/8, 172.16/12, 192.168/16, fc00::/7), not link-local
        # (169.254/16, fe80::/10), not unspecified, and not in a special-use
        # range — with IPv4-mapped IPv6 unwrapped first so ::ffff:10.0.0.5
        # cannot slip through.
        def public_address?(ip)
          ip = ip.native if ip.ipv4_mapped?
          return false if ip.loopback? || ip.private? || ip.link_local? || ip.to_i.zero?

          SPECIAL_USE_RANGES.none? { |range| address_in_range?(range, ip) }
        end

        def address_in_range?(range, ip)
          range.include?(ip)
        rescue IPAddr::InvalidAddressError
          false # family mismatch (IPv4 range vs IPv6 address, or vice versa)
        end
      end
    end
  end
end
