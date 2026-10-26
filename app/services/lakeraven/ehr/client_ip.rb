# frozen_string_literal: true

require "ipaddr"

module Lakeraven
  module EHR
    # Client address for RateLimit and for LoginThrottle (SessionsController
    # passes the result into the account/IP pair).
    #
    # Walks REMOTE_ADDR and X-Forwarded-For from the right — the hop closest
    # to this process first — and returns the first address that is not a
    # configured trusted proxy. With no trusted proxies configured, the
    # client is REMOTE_ADDR and X-Forwarded-For is ignored. A caller who
    # can set that header must not be able to choose a fresh throttle bucket.
    #
    # Deployment requirement: configure trusted proxies
    # (Rails config.action_dispatch.trusted_proxies) when this process sits
    # behind a load balancer. Until that list is set, every user shares the
    # balancer's address and a forged X-Forwarded-For is not believed.
    module ClientIp
      module_function

      def resolve(request)
        remote = header(request, "REMOTE_ADDR")
        proxies = configured_proxies
        return present(remote) if proxies.empty?

        present(untrusted_hop(remote, forwarded_for(request), proxies) || remote)
      end

      def configured_proxies
        Array(Rails.application.config.action_dispatch.trusted_proxies).compact
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
