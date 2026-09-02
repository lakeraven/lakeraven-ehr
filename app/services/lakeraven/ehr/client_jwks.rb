# frozen_string_literal: true

require "net/http"

module Lakeraven
  module EHR
    # Fetches a backend client's published JWKS (SMART Backend Services).
    #
    # The client publishes and rotates its keys at a JWKS URL registered on
    # its Doorkeeper application (jwks_uri). A short cache TTL keeps key
    # rotation timely without refetching on every token request.
    class ClientJwks
      CACHE_TTL = 5.minutes
      FETCH_TIMEOUT = 5 # seconds

      class << self
        # Returns the parsed JWKS as a symbol-keyed hash ({ keys: [...] }),
        # or nil when the JWKS cannot be fetched or parsed.
        def fetch(jwks_uri)
          return nil if jwks_uri.blank?

          Rails.cache.fetch("client_jwks/#{jwks_uri}", expires_in: CACHE_TTL) do
            fetch_uncached(jwks_uri)
          end
        end

        private

        def fetch_uncached(jwks_uri)
          uri = URI.parse(jwks_uri)
          return nil unless uri.is_a?(URI::HTTP)

          response = Net::HTTP.start(uri.host, uri.port,
                                     use_ssl: uri.scheme == "https",
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
      end
    end
  end
end
