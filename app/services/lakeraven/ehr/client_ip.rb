# frozen_string_literal: true

require "ipaddr"

module Lakeraven
  module EHR
    # Client address for RateLimit and for LoginThrottle (SessionsController
    # passes the result into the account/IP pair).
    #
    # Walks REMOTE_ADDR and X-Forwarded-For from the right — the hop closest
    # to this process first — and returns the first address that is not a
    # trusted proxy. A public REMOTE_ADDR is that address, so a caller who
    # can set X-Forwarded-For must not be able to choose a fresh bucket.
    #
    # With no explicit list, the default is Rails'
    # ActionDispatch::RemoteIp::TRUSTED_PROXIES (loopback and private ranges).
    # A process behind a proxy in those ranges therefore keys on the client
    # in X-Forwarded-For. config.action_dispatch.trusted_proxies replaces
    # that default when an operator needs a narrower or wider set.
    # LoginThrottle sees the same address: SessionsController passes it in.
    module ClientIp
      module_function

      def resolve(request)
        remote = header(request, "REMOTE_ADDR")
        present(untrusted_hop(remote, forwarded_for(request), effective_proxies) || remote)
      end

      # The raw operator list. Empty means "no explicit config", not "trust
      # nobody": resolve falls back to Rails' private-range defaults.
      def configured_proxies
        Array(Rails.application.config.action_dispatch.trusted_proxies).compact
      end

      def effective_proxies
        configured = configured_proxies
        return configured if configured.any?

        ActionDispatch::RemoteIp::TRUSTED_PROXIES
      end

      def forwarded_for(request)
        header(request, "HTTP_X_FORWARDED_FOR").split(",").map(&:strip).reject(&:empty?)
      end

      def untrusted_hop(remote, forwarded, proxies)
        hops = [ remote, *forwarded.reverse ]
        hops.each do |hop|
          candidate = hop.to_s.strip
          next if candidate.empty?
          return candidate unless trusted?(candidate, proxies)
        end
        nil
      end

      def trusted?(ip, proxies)
        proxies.any? { |proxy| proxy_match?(proxy, ip) }
      end

      def proxy_match?(proxy, ip)
        return true if proxy === ip
        return false unless proxy.is_a?(String)

        IPAddr.new(proxy) === ip
      rescue StandardError
        false
      end

      def header(request, name)
        request.get_header(name).to_s
      end

      def present(ip)
        ip.to_s.strip.presence || "unknown"
      end
    end
  end
end
